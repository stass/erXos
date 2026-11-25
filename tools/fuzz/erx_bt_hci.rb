# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true
# erx-gate: fuzz seeded deadline=300

require 'open3'
require 'optparse'
require 'tmpdir'
require_relative '../lib/erx/generated'
require_relative '../lib/erx/fuzz_warm'

# The fuzz target of the Bluetooth controller's line, erx_h4:split/1, erx_hci:event/2
# and erx_hci:return/2, and of the patch file, erx_bt_patch:parse/1
# (test/erlang/erx_bt_hci_fuzz.erl), compiled from source and run
# alone on stock's emulator (ERX_ERL and ERX_ERLC, the oracle's), so it needs no hosted
# build. It runs the sources as they are, then, for each seeded fault, a copy of the
# module with the fault in place, which must fail with the verdict the fault breaks.
module ErxBtHciFuzz
  ROOT = File.expand_path('../..', __dir__)
  H4 = 'erlang/apps/erx_bt/src/erx_h4.erl'
  HCI = 'erlang/apps/erx_bt/src/erx_hci.erl'
  PATCH = 'erlang/apps/erx_bt/src/erx_bt_patch.erl'
  FUZZ = 'test/erlang/erx_bt_hci_fuzz.erl'
  # Each of the four runs takes about two seconds; each compile and run is under this
  # deadline, and tools/erx gives the whole runner 300.
  DEADLINE_SECONDS = '60'

  # A seeded fault: the module's anchor replaced, and the error term the run must fail
  # with, matched with its opening brace so one verdict is not read inside another.
  Fault = Data.define(:fault, :module_path, :anchor, :replacement, :verdict)

  FAULTS = [
    Fault.new(fault: 'the patch record length not checked against the bytes left',
              module_path: PATCH,
              anchor: "parse(_Bytes, Offset, _Records) ->\n    throw({truncated, Offset}).",
              replacement: "parse(<<Opcode:16/little, _Length, Payload/binary>>, _Offset, Records) ->\n" \
                           "    lists:reverse([{Opcode, Payload} | Records]);\n" \
                           "parse(_Bytes, Offset, _Records) ->\n    throw({truncated, Offset}).",
              verdict: '{patch_accepted_wrongly,'),
    Fault.new(fault: 'the ACL bound removed from split/1',
              module_path: H4,
              anchor: 'when Length > ?ERX_BT_ACL_RX_MAX ->',
              replacement: 'when Length > 16#FFFF ->',
              verdict: '{acl_over_bound,'),
    Fault.new(fault: 'Number Of Completed Packets read without checking Num_Handles against the pairs',
              module_path: HCI,
              anchor: 'when byte_size(Pairs) =:= Count * 4 ->',
              replacement: 'when byte_size(Pairs) rem 4 =:= 0 ->',
              verdict: '{length_disagrees,'),
    Fault.new(fault: 'a reserved handle folded onto a live one',
              module_path: HCI,
              anchor: 'handle(_Word) -> throw(malformed).',
              replacement: 'handle(Word) -> Word band 16#EFF.',
              verdict: '{decoded_wrongly,'),
    Fault.new(fault: "Read Buffer Size's return taken with bytes after its layout",
              module_path: HCI,
              anchor: 'Packets:16/little, _SyncPackets:16>>) ->',
              replacement: 'Packets:16/little, _SyncPackets:16, _/binary>>) ->',
              verdict: '{return_length_disagrees,'),
    Fault.new(fault: "a Long Term Key reply's return taken with a reserved handle",
              module_path: HCI,
              anchor: 'try {ok, handle(Word)} catch throw:malformed -> malformed end;',
              replacement: '{ok, Word band 16#FFF};',
              verdict: '{return_handle_disagrees,'),
    Fault.new(fault: "a failed LE Connection Complete's handle and address type checked before its Status",
              module_path: HCI,
              anchor: "<<Status, _/binary>>) when Status =/= ?ERX_HCI_STATUS_SUCCESS ->\n" \
                      "    {le_connection_complete, {failed, Status}};",
              replacement: "<<Status, Handle:16/little, _Role, PeerType, _/binary>>) when Status =/= ?ERX_HCI_STATUS_SUCCESS ->\n" \
                           "    _ = {handle(Handle), peer_type(PeerType)},\n" \
                           "    {le_connection_complete, {failed, Status}};",
              verdict: '{failed_connection_malformed,'),
    Fault.new(fault: "LE Connection Complete's Peer_Address_Type passed through as its octet",
              module_path: HCI,
              anchor: '{le_connection_complete, handle(Handle), {peer_type(PeerType), reverse(Peer)}};',
              replacement: '{le_connection_complete, handle(Handle), {PeerType, reverse(Peer)}};',
              verdict: '{reserved_peer_type,')
  ].freeze

  module_function

  def run(seed:)
    Erx::Generated.ensure(root: ROOT)
    output, status = fuzz({}, seed: seed)
    abort(output) unless status.success? && output.match?(/^fuzz: \d+ rounds ok, /)
    FAULTS.each { |fault| run_fault(fault, seed: seed) }
    puts output[/^fuzz: .*$/]
    puts "erx_h4 and erx_hci read every controller input, and erx_bt_patch every patch file, without a " \
         "raise or an atom, and #{FAULTS.size} " \
         'seeded faults each fail their verdict'
  end

  def run_fault(fault, seed:)
    source = File.binread(File.join(ROOT, fault.module_path))
    raise "seed anchor for #{fault.fault} is not unique" unless source.scan(fault.anchor).size == 1

    output, status = fuzz({ fault.module_path => source.sub(fault.anchor) { fault.replacement } }, seed: seed)
    abort("#{fault.fault}: the fuzz run passed:\n#{output}") if status.success? || !output.include?(fault.verdict)
  end

  # In a directory of its own, which also takes the crash dump of a failed round; a
  # replaced module is compiled from its copy there.
  def fuzz(replaced, seed:)
    Dir.mktmpdir('erx-bt-hci-fuzz') do |work|
      sources = [H4, HCI, PATCH, FUZZ].map do |source|
        next File.join(ROOT, source) unless replaced.key?(source)

        File.join(work, File.basename(source)).tap { |path| File.binwrite(path, replaced.fetch(source)) }
      end
      include = Erx::Generated.path('erlang/apps/erx/include', root: ROOT)
      output, status = Open3.capture2e('gtimeout', '-k', '10', DEADLINE_SECONDS, ENV.fetch('ERX_ERLC'), '-I', include,
                                       '-o', work, *sources, Erx::FuzzWarm::SOURCE, stdin_data: '')
      raise output unless status.success?

      Open3.capture2e('gtimeout', '-k', '10', DEADLINE_SECONDS, ENV.fetch('ERX_ERL'), '-noshell', '-pa', work,
                      '-run', 'erx_bt_hci_fuzz', 'run', seed.to_s, '-s', 'init', 'stop',
                      chdir: work, stdin_data: '')
    end
  end
end

if $PROGRAM_NAME == __FILE__
  seed = 1
  OptionParser.new { |flags| flags.on('--seed N', Integer) { |value| seed = value } }.parse!
  ErxBtHciFuzz.run(seed: seed)
end
