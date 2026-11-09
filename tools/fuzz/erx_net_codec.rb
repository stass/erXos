# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'open3'
require 'optparse'
require 'tmpdir'
require_relative '../lib/erx/dependencies'
require_relative '../lib/erx/generated'

# The fuzz targets of the network stack's codecs (docs/design-network-stack.md,
# "Codecs: fuzz targets"): erx_net_eth, erx_arp_wire, erx_ip4_wire, erx_icmp4_wire,
# erx_udp_wire, erx_ip6_wire, erx_icmp6_wire, erx_tcp_wire and erx_dhcp4_wire, and the quoted-packet decoders of erx_icmp4 and
# erx_icmp6, each driven by test/erlang/MODULE_fuzz.erl,
# compiled from source with the host's model of erx_bytes and with msantos/pkt (deps.lock's fetched tree) behind
# erx_net_pkt_oracle, and run alone on stock's emulator (ERX_ERL and ERX_ERLC, the
# oracle's). Each target runs its decoder as it is, then a copy with one seeded fault that
# must fail the target, which shows the target reaches the code the fault changes.
module ErxNetCodecFuzz
  ROOT = File.expand_path('../..', __dir__)
  APPLICATION = File.join(ROOT, 'erlang/apps/erx_net')
  HOST_BYTES = File.join(ROOT, 'test/erlang/host_bytes/erx_bytes.erl')
  ORACLE = File.join(ROOT, 'test/erlang/erx_net_pkt_oracle.erl')
  DEADLINE_SECONDS = '300'

  # The failures of a round that show it reached the faulty code: a raise, a refusal or
  # acceptance the reference judge disputes, or a record that does not encode back.
  CAUGHT = %w[raised disagrees_with_reference round_trip_differs fields_differ lease_out_of_bounds].freeze

  # A target: the module under test, its seeded fault as the text it replaces, and the
  # failure tags that count as catching it (any of CAUGHT unless the fault is aimed at one).
  Target = Data.define(:module_name, :exact, :faulty, :fault, :caught) do
    def initialize(caught: CAUGHT, **fields) = super
  end

  TARGETS = {
    'eth' => Target.new(module_name: 'erx_net_eth',
                        exact: 'decode(<<Dst:6/binary, Src:6/binary, Type:16, Payload/binary>>) ->',
                        faulty: 'decode(<<Dst:6/binary, Src:6/binary, Type:8, Payload/binary>>) ->',
                        fault: 'reading a one-byte EtherType'),
    'arp' => Target.new(module_name: 'erx_arp_wire',
                        exact: "        Hln =/= ?ETHER_ADDR_LEN -> {error, bad_hardware};\n",
                        faulty: '',
                        fault: 'skipping the hardware address length check'),
    'ip4' => Target.new(module_name: 'erx_ip4_wire',
                        exact: 'payload(Rest, Length) when Length =< byte_size(Rest) -> {ok, binary:part(Rest, 0, Length)};',
                        faulty: 'payload(Rest, Length) -> {ok, binary:part(Rest, 0, min(Length, byte_size(Rest)))};',
                        fault: 'trusting the total length without checking it against the packet'),
    'icmp4' => Target.new(module_name: 'erx_icmp4_wire',
                          exact: 'Hl >= ?IP_HDR_WORDS andalso byte_size(Invoking) >= Hl * 4 + 8;',
                          faulty: 'Hl >= ?IP_HDR_WORDS;',
                          fault: 'accepting an error message whose quoted header runs past the message'),
'icmp4_quoted' => Target.new(module_name: 'erx_icmp4',
                             exact: 'when Hl >= 5, byte_size(Invoking) >= Hl * 4 + ?ICMP_MINLEN ->',
                             faulty: 'when Hl >= 5 ->',
                             fault: 'accepting a quoted header without the 8 bytes after it'),
    'udp' => Target.new(module_name: 'erx_udp_wire',
                        exact: 'checksum(with_length(PseudoSum, byte_size(Bytes), Ulen), Datagram).',
                        faulty: 'checksum(PseudoSum, Datagram).',
                        fault: 'summing the pseudo-header over the bytes delivered instead of the UDP length'),
    'ip6' => Target.new(module_name: 'erx_ip6_wire',
                        exact: '_Short -> {error, truncated}',
                        faulty: 'Short -> fixed(Header, Short)',
                        fault: 'trusting the payload length without checking it against the packet'),
    'icmp6' => Target.new(module_name: 'erx_icmp6_wire',
                          exact: '_Overrun -> {error, bad_option}',
                          faulty: 'Overrun -> nd_options(<<>>, Seen + 1, nd_option(Type, Len, Overrun, Opts))',
                          fault: 'accepting a neighbour-discovery option past the end of the message'),
'icmp6_quoted' => Target.new(module_name: 'erx_icmp6',
                             exact: '{_, Off} when Off + ?UPPER_MIN > byte_size(Invoking) ->',
                             faulty: '{_, Off} when Off > byte_size(Invoking) ->',
                             fault: 'accepting a quoted packet without 8 bytes of its upper-layer header'),
    'dhcp4' => Target.new(module_name: 'erx_dhcp4_wire',
                          exact: 'hlen(Hlen) when Hlen =< ?CHADDR_BYTES -> ok;',
                          faulty: 'hlen(_) -> ok;',
                          fault: 'trusting a hardware address length over 16'),
    'dhcp4_join' => Target.new(module_name: 'erx_dhcp4_wire',
                               exact: 'raw_options(Rest, maps:update_with(Code, fun(Seen) -> [Data | Seen] end, [Data], Acc));',
                               faulty: 'raw_options(Rest, Acc#{Code => [Data]});',
                               fault: 'keeping only the last instance of a long option'),
    'dhcp4_routes' => Target.new(module_name: 'erx_dhcp4_wire',
                                 exact: 'classless_routes(<<Plen, Rest/binary>>, Routes) when Plen =< ?PLEN_MAX ->',
                                 faulty: 'classless_routes(<<Plen, Rest/binary>>, Routes) when Plen =< ?PLEN_MAX + 1 ->',
                                 fault: 'reading a classless route prefix length of 33'),
    'tcp' => Target.new(module_name: 'erx_tcp_wire',
                        exact: 'header(<<_:96, Off:4, _:12, _/binary>> = Segment) when Off < ?TCP_HDR_WORDS; Off * 4 > byte_size(Segment) ->',
                        faulty: 'header(<<_:96, Off:4, _:12, _/binary>> = Segment) when Off * 4 > byte_size(Segment) ->',
                        fault: 'accepting a data offset below 5'),
    # The data-offset fault is caught by a raise; this one only by the judge's options.
    'tcp_sack' => Target.new(module_name: 'erx_tcp_wire',
                             exact: 'option(?TCPOPT_SACK, Blocks, false, Opts)',
                             faulty: 'option(?TCPOPT_SACK, Blocks, _, Opts)',
                             fault: 'accepting SACK blocks on a SYN', caught: %w[disagrees_with_reference])
  }.freeze

  module_function

  def run(target:, seed:)
    spec = TARGETS.fetch(target)
    path = File.join(APPLICATION, 'src', "#{spec.module_name}.erl")
    source = File.binread(path)
    raise "#{path} lacks the text its seeded fault replaces" unless source.include?(spec.exact)

    output, status = fuzz(spec.module_name, source, seed: seed)
    abort(output) unless status.success? && output.match?(/^fuzz: \d+ rounds ok, \d+ accepted$/)
    output, status = fuzz(spec.module_name, source.sub(spec.exact, spec.faulty), seed: seed)
    abort("#{spec.fault} passed:\n#{output}") if status.success? || spec.caught.none? { |tag| output.include?(tag) }
    puts "#{spec.module_name}:decode agrees with its reference and pkt, and #{spec.fault} does not " \
         "(#{output[/^fuzz: (\w+)/, 1]})"
  end

  # In a directory of its own, which also takes the crash dump of a failed round.
  def fuzz(module_name, module_text, seed:)
    Dir.mktmpdir('erx-net-codec-fuzz') do |work|
      module_path = File.join(work, "#{module_name}.erl")
      File.binwrite(module_path, module_text)
      pkt = Erx::Dependencies.new(root: ROOT, runner: nil).fetched_tree('pkt')
      pkt_include = File.join(pkt, 'include')
      compile(work, Dir[File.join(pkt, 'src', '*.erl')].sort, includes: ['-I', pkt_include])
      others = Dir[File.join(APPLICATION, 'src', '*.erl')].sort.reject { |path| File.basename(path, '.erl') == module_name }
      compile(work, [module_path, *others, HOST_BYTES, ORACLE, File.join(ROOT, "test/erlang/#{module_name}_fuzz.erl")],
              includes: ['-I', File.join(APPLICATION, 'include'), '-I', pkt_include])
      Open3.capture2e('gtimeout', '-k', '10', DEADLINE_SECONDS, ENV.fetch('ERX_ERL'), '-noshell', '-pa', work,
                      '-run', "#{module_name}_fuzz", 'run', seed.to_s, '-s', 'init', 'stop',
                      chdir: work, stdin_data: '')
    end
  end

  def compile(work, sources, includes:)
    output, status = Open3.capture2e(ENV.fetch('ERX_ERLC'), *includes, '-pa', work, '-o', work, *sources,
                                     stdin_data: '')
    raise output unless status.success?
  end
end

if $PROGRAM_NAME == __FILE__
  options = { seed: 1 }
  OptionParser.new do |flags|
    flags.on('--target NAME', ErxNetCodecFuzz::TARGETS.keys) { |value| options[:target] = value }
    flags.on('--seed N', Integer) { |value| options[:seed] = value }
  end.parse!
  ErxNetCodecFuzz.run(target: options.fetch(:target), seed: options.fetch(:seed))
end
