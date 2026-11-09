# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'open3'
require 'optparse'
require 'tmpdir'
require_relative '../lib/erx/dependencies'

# The fuzz target of erx_net_input (docs/design-network-stack.md, "Classification and
# framing"), driven by test/erlang/erx_net_input_fuzz.erl: compiled from source with the
# host's model of erx_bytes and with msantos/pkt (deps.lock's fetched tree) behind
# erx_net_pkt_oracle, and run on stock's emulator (ERX_ERL and ERX_ERLC, the oracle's).
# It runs the classifier as it is, then each copy seeded with one of the design's five
# faults and the loopback-zone fault, each of which must fail the target by the
# property its entry names.
module ErxNetInputFuzz
  ROOT = File.expand_path('../..', __dir__)
  APPLICATION = File.join(ROOT, 'erlang/apps/erx_net')
  SOURCE = File.join(APPLICATION, 'src/erx_net_input.erl')
  HOST_BYTES = File.join(ROOT, 'test/erlang/host_bytes/erx_bytes.erl')
  ORACLE = File.join(ROOT, 'test/erlang/erx_net_pkt_oracle.erl')
  TARGET = File.join(ROOT, 'test/erlang/erx_net_input_fuzz.erl')
  DEADLINE_SECONDS = '600'

  # A seeded fault: the text of erx_net_input.erl it replaces, what it does, and the
  # failure tags of the target that may catch it.
  Fault = Data.define(:exact, :faulty, :fault, :caught)
  JUDGE = %w[disagrees_with_reference].freeze

  FAULTS = [
    Fault.new(exact: 'Keys = [{udp, Family, Dst, Dport, Src, Sport}, {udp, Family, Dst, Dport}, {udp, Family, any, Dport}],',
              faulty: 'Keys = [{udp, Family, any, Dport}],',
              fault: 'looking a UDP datagram up by its port alone', caught: JUDGE),
    Fault.new(exact: '{ok, Entry} when LinkCast =:= unicast -> {local, {tcp, Head, Upper, Entry}};',
              faulty: '{ok, Entry} when is_atom(LinkCast) -> {local, {tcp, Head, Upper, Entry}};',
              fault: 'keeping a link-layer broadcast segment for a listener', caught: JUDGE),
    Fault.new(exact: "tcp(\#{family := Family, src := Src, dst := Dst, link := LinkCast} = Head,\n",
              faulty: "tcp(_, <<_:13/binary, _:5, 1:1, _:2, _/binary>>, _) -> {drop, no_reply};\n" \
                      "tcp(\#{family := Family, src := Src, dst := Dst, link := LinkCast} = Head,\n",
              fault: 'reading the RST flag before verification',
              caught: %w[disagrees_with_reference verdict_read_unnamed_byte]),
    Fault.new(exact: 'src => erx_net_addr:zoned(Src, Zone), dst => erx_net_addr:zoned(Dst, Zone), zone => Zone}.',
              faulty: 'src => Src, dst => Dst, zone => Zone}.',
              fault: 'building keys from link-local addresses without their zone', caught: JUDGE),
    Fault.new(exact: "    case dhcp(Packet) of\n        {ok, Ip, Upper} -> {local, {dhcp, Ip, Upper}};\n" \
                     "        no -> ip4(Packet, LinkCast, View)\n    end;\n",
              faulty: "    case {ip4(Packet, LinkCast, View), Packet} of\n" \
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
              fault: 'giving a looped packet the zone of the loopback interface', caught: JUDGE)
  ].freeze

  module_function

  def run(seed:)
    source = File.binread(SOURCE)
    output, status = fuzz(source, seed: seed)
    abort(output) unless status.success? && output.match?(/^fuzz: \d+ rounds ok, \d+ accepted$/)
    FAULTS.each do |spec|
      raise "#{SOURCE} lacks the text its seeded fault replaces: #{spec.fault}" unless source.include?(spec.exact)

      output, status = fuzz(source.sub(spec.exact, spec.faulty), seed: seed)
      abort("#{spec.fault} passed:\n#{output}") if status.success? || spec.caught.none? { |tag| output.include?(tag) }
    end
    puts "erx_net_input agrees with its reference judge, and #{FAULTS.map(&:fault).join('; ')} do not"
  end

  # In a directory of its own, which also takes the crash dump of a failed round.
  def fuzz(module_text, seed:)
    Dir.mktmpdir('erx-net-input-fuzz') do |work|
      module_path = File.join(work, 'erx_net_input.erl')
      File.binwrite(module_path, module_text)
      pkt = Erx::Dependencies.new(root: ROOT, runner: nil).fetched_tree('pkt')
      pkt_include = File.join(pkt, 'include')
      compile(work, Dir[File.join(pkt, 'src', '*.erl')].sort, includes: ['-I', pkt_include])
      others = Dir[File.join(APPLICATION, 'src', '*.erl')].sort.reject { |path| path == SOURCE }
      compile(work, [module_path, *others, HOST_BYTES, ORACLE, TARGET],
              includes: ['-I', File.join(APPLICATION, 'include'), '-I', pkt_include])
      Open3.capture2e('gtimeout', '-k', '10', DEADLINE_SECONDS, ENV.fetch('ERX_ERL'), '-noshell', '-pa', work,
                      '-run', 'erx_net_input_fuzz', 'run', seed.to_s, '-s', 'init', 'stop',
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
    flags.on('--seed N', Integer) { |value| options[:seed] = value }
  end.parse!
  ErxNetInputFuzz.run(seed: options.fetch(:seed))
end
