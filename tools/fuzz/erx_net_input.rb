# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'open3'
require 'optparse'
require 'tmpdir'
require_relative '../lib/erx/dependencies'
require_relative '../lib/erx/erx_net_host'

# The fuzz target of erx_net_input (docs/design-network-stack.md, "Classification and
# framing"), driven by test/erlang/erx_net_input_fuzz.erl: compiled from source with the
# portable erx_bytes over its C library (Erx::ErxNetHost) and with msantos/pkt (deps.lock's fetched tree) behind
# erx_net_pkt_oracle, and run on stock's emulator (ERX_ERL and ERX_ERLC, the oracle's).
# It runs the classifier as it is, then each copy seeded with one of FAULTS, each of which
# must fail the target with a failure tag its entry names.
module ErxNetInputFuzz
  ROOT = File.expand_path('../..', __dir__)
  APPLICATION = File.join(ROOT, 'erlang/apps/erx_net')
  SOURCE = File.join(APPLICATION, 'src/erx_net_input.erl')
  PORTABLE_BYTES = File.join(APPLICATION, 'portable/erx_bytes.erl')
  ORACLE = File.join(ROOT, 'test/erlang/erx_net_pkt_oracle.erl')
  TARGET = File.join(ROOT, 'test/erlang/erx_net_input_fuzz.erl')
  DEADLINE_SECONDS = '600'

  # A seeded fault: the text it replaces in the source it names (erx_net_input.erl unless
  # it says otherwise), what it does, and the failure tags of the target that may catch it.
  Fault = Data.define(:exact, :faulty, :fault, :caught, :source) do
    def initialize(source: SOURCE, **fields) = super
  end
  JUDGE = %w[disagrees_with_reference].freeze

  FAULTS = [
    Fault.new(exact: 'Keys = [{udp, Family, Dst, Dport, Src, Sport}, {udp, Family, Dst, Dport}, {udp, Family, any, Dport}],',
              faulty: 'Keys = [{udp, Family, any, Dport}],',
              fault: 'looking a UDP datagram up by its port alone', caught: JUDGE),
    Fault.new(exact: '{ok, Entry} when LinkCast =:= unicast, Cast =:= unicast -> {local, {tcp, Head, Upper, Entry}};',
              faulty: '{ok, Entry} when Cast =:= unicast -> {local, {tcp, Head, Upper, Entry}};',
              fault: 'keeping a link-layer broadcast segment for a listener', caught: JUDGE),
    Fault.new(exact: "tcp(\#{family := Family,",
              faulty: "tcp(_, <<_:13/binary, _:5, 1:1, _:2, _/binary>>, _) -> {drop, no_reply};\n" \
                      "tcp(\#{family := Family,",
              fault: 'reading the RST flag before verification', caught: %w[verdict_read_unnamed_byte]),
    Fault.new(exact: 'src => erx_net_addr:zoned(Src, Zone), dst => erx_net_addr:zoned(Dst, Zone), zone => Zone}.',
              faulty: 'src => Src, dst => Dst, zone => Zone}.',
              fault: 'building keys from link-local addresses without their zone', caught: JUDGE),
    Fault.new(exact: "    case dhcp(Packet) of\n        {ok, Ip, Upper} -> {local, {dhcp, Ip, Upper}};\n" \
                     "        no -> ip4(Packet, Sum, LinkCast, View)\n    end;\n",
              faulty: "    case {ip4(Packet, Sum, LinkCast, View), Packet} of\n" \
                      "        {{drop, not_ours}, <<4:4, Hl:4, _:8/binary, 17, _/binary>>}\n" \
                      "          when Hl >= 5, byte_size(Packet) >= Hl * 4 + 8 ->\n" \
                      "            Upper = binary:part(Packet, Hl * 4, byte_size(Packet) - Hl * 4),\n" \
                      "            Ip = #ip4{p = 17, src = binary:part(Packet, 12, 4), dst = binary:part(Packet, 16, 4)},\n" \
                      "            case Upper of\n" \
                      "                <<_:16, 68:16, _/binary>> -> {local, {dhcp, Ip, Upper}};\n" \
                      "                _ -> {drop, not_ours}\n" \
                      "            end;\n" \
                      "        {Verdict, _} -> Verdict\n    end;\n",
              fault: 'taking port 68 for DHCP only after not_ours, by decoding again', caught: JUDGE),
    Fault.new(exact: "classify({frame, Zone, Bytes}, \#{link := none} = View) ->\n",
              faulty: "classify({frame, _, Bytes}, \#{link := none, ip6 := \#{zone := Zone}} = View) ->\n",
              fault: 'giving a looped packet the zone of the loopback interface', caught: JUDGE),
    Fault.new(source: File.join(APPLICATION, 'src/erx_icmp4.erl'),
              exact: '<<_:Hl/unit:32, Upper/binary>> = Invoking,',
              faulty: '<<_:20/binary, Upper/binary>> = Invoking,',
              fault: "reading a quote's ports at 20 bytes whatever its header length", caught: JUDGE),
    Fault.new(exact: "?IP6_HDR_LEN + HdrLen));", faulty: "?IP6_HDR_LEN));",
              fault: "deriving an IPv6 datagram's sum above IP without its extension headers",
                caught: %w[network_sum_differs]),
      Fault.new(exact: 'case is_integer(N) andalso N >= 2 andalso length(Payload) =< N andalso N =< MaxFrames of',
                faulty: 'case is_integer(N) andalso MaxFrames > 0 of',
                fault: "charging a unit's count without checking it against its pieces and the merge's limit",
                caught: %w[forged_unit_accepted]),
      Fault.new(exact: '        andalso LastSeq =:= erx_tcp_seq:wire(Seq + Size - byte_size(LastPayload))',
                faulty: '        andalso is_integer(LastSeq) andalso is_binary(LastPayload)',
                fault: "taking a unit whose pieces end before its last frame starts", caught: %w[forged_unit_accepted]),
      Fault.new(exact: 'unit(N, ether(First, FirstSum, View), fun() -> ether(Last, LastSum, View) end, Payload);',
                faulty: 'unit(N, ether(Last, LastSum, View), fun() -> ether(First, FirstSum, View) end, Payload);',
                fault: 'classifying a unit by its last frame',
                caught: %w[unit_bytes_not_the_streams unit_ack_not_the_last unit_not_its_last_frame])
  ].freeze

  module_function

  def run(seed:)
    output, status = fuzz(SOURCE, File.binread(SOURCE), seed: seed)
    abort(output) unless status.success? && output.match?(/^fuzz: \d+ rounds ok, \d+ accepted$/)
    FAULTS.each do |spec|
      source = File.binread(spec.source)
      raise "#{spec.source} lacks the text its seeded fault replaces: #{spec.fault}" unless source.include?(spec.exact)

      output, status = fuzz(spec.source, source.sub(spec.exact, spec.faulty), seed: seed)
      abort("#{spec.fault} passed:\n#{output}") if status.success? || spec.caught.none? { |tag| output.match?(/^fuzz: #{Regexp.escape(tag)}\b/) }
      puts "#{spec.fault}: caught as #{output[/^fuzz: (\w+)/, 1]}"
    end
    puts 'erx_net_input agrees with its reference judge, and every seeded fault fails it'
  end

  # Path's module replaced by module_text, in a directory of its own, which also takes the
  # crash dump of a failed round.
  def fuzz(path, module_text, seed:)
    Dir.mktmpdir('erx-net-input-fuzz') do |work|
      module_path = File.join(work, File.basename(path))
      File.binwrite(module_path, module_text)
      pkt = Erx::Dependencies.new(root: ROOT, runner: nil).fetched_tree('pkt')
      pkt_include = File.join(pkt, 'include')
      ebin = Erx::ErxNetHost.lay_out(work, erl: ENV.fetch('ERX_ERL'))
      compile(ebin, Dir[File.join(pkt, 'src', '*.erl')].sort, includes: ['-I', pkt_include])
      others = Dir[File.join(APPLICATION, 'src', '*.erl')].sort.reject { |other| other == path }
      compile(ebin, [module_path, *others, PORTABLE_BYTES, ORACLE, TARGET],
              includes: ['-I', File.join(APPLICATION, 'include'), '-I', pkt_include])
      Open3.capture2e('gtimeout', '-k', '10', DEADLINE_SECONDS, ENV.fetch('ERX_ERL'), '-noshell', '-pa', ebin,
                      '-run', 'erx_net_input_fuzz', 'run', seed.to_s, '-s', 'init', 'stop',
                      chdir: work, stdin_data: '')
    end
  end

  def compile(ebin, sources, includes:)
    output, status = Open3.capture2e(ENV.fetch('ERX_ERLC'), *includes, '-pa', ebin, '-o', ebin, *sources,
                                     stdin_data: '')
    raise output unless status.success?
  end
end

if $PROGRAM_NAME == __FILE__
  options = { seed: 1 }
  OptionParser.new do |flags|
    flags.on('--seed N', Integer) { |value| options[:seed] = value }
  end.parse!
  ErxNetInputFuzz.run(seed: options.fetch(:seed))
end
