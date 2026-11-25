# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true
# erx-gate: fuzz seeded deadline=300

require 'open3'
require 'optparse'
require 'tmpdir'
require_relative '../lib/erx/generated'
require_relative '../lib/erx/fuzz_warm'

# The fuzz target of what a phone sends on an LE link: L2CAP's reassembly and LE signaling
# (erx_l2cap:reassemble/3, signal/1) and the ATT codec with the server over it
# (erx_att:decode/1, erx_gatt_server:request/3), test/erlang/erx_bt_att_fuzz.erl, compiled
# from source with erx_bytes's stand-in and run alone on stock's emulator (ERX_ERL and
# ERX_ERLC, the oracle's), so it needs no hosted build. It runs the sources as they are,
# then, for each seeded fault, a copy of the module with the fault in place, which must
# fail with the verdict the fault breaks.
module ErxBtAttFuzz
  ROOT = File.expand_path('../..', __dir__)
  L2CAP = 'erlang/apps/erx_bt/src/erx_l2cap.erl'
  ATT = 'erlang/apps/erx_bt/src/erx_att.erl'
  SERVER = 'erlang/apps/erx_bt/src/erx_gatt_server.erl'
  SOURCES = [L2CAP, ATT, 'erlang/apps/erx_bt/src/erx_gatt_db.erl', 'erlang/apps/erx_bt/src/erx_gatt_gate.erl', SERVER,
             'test/erlang/host_bytes/erx_bytes.erl', 'test/erlang/erx_bt_att_fuzz.erl'].freeze
  # Each run is under this deadline, and tools/erx gives the whole runner 300.
  DEADLINE_SECONDS = '60'

  # A seeded fault: the module's anchor replaced, and the error term the run must fail
  # with, matched with its opening brace so one verdict is not read inside another.
  Fault = Data.define(:fault, :module_path, :anchor, :replacement, :verdict)

  FAULTS = [
    Fault.new(fault: "a frame's channel bound removed",
              module_path: L2CAP,
              anchor: 'Bound when Length > Bound -> {error, {too_long, Cid, Length}};',
              replacement: 'Bound when false -> {error, {too_long, Cid, Length}};',
              verdict: '{frame_over_bound,'),
    Fault.new(fault: "Read Blob's offset read big-endian",
              module_path: ATT,
              anchor: 'decode(<<?ERX_ATT_OPCODE_READ_BLOB_REQ, Handle:16/little, Offset:16/little>>) ->',
              replacement: 'decode(<<?ERX_ATT_OPCODE_READ_BLOB_REQ, Handle:16/little, Offset:16/big>>) ->',
              verdict: '{decoded_wrongly,'),
    Fault.new(fault: "a Read Response not cut to the bearer's MTU",
              module_path: SERVER,
              anchor: '?SEND({read, binary:part(Value, 0, min(byte_size(Value), Mtu - 1))}, Bearer);',
              replacement: '?SEND({read, Value}, Bearer);',
              verdict: '{response_over_mtu,')
  ].freeze

  module_function

  def run(seed:)
    Erx::Generated.ensure(root: ROOT)
    output, status = fuzz({}, seed: seed)
    abort(output) unless status.success? && output.match?(/^fuzz: \d+ rounds ok, /)
    FAULTS.each { |fault| run_fault(fault, seed: seed) }
    puts output[/^fuzz: .*$/]
    puts "erx_l2cap, erx_att and erx_gatt_server read every PDU a phone sends without a raise or an atom, " \
         "and #{FAULTS.size} seeded faults each fail their verdict"
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
    Dir.mktmpdir('erx-bt-att-fuzz') do |work|
      sources = SOURCES.map do |source|
        next File.join(ROOT, source) unless replaced.key?(source)

        File.join(work, File.basename(source)).tap { |path| File.binwrite(path, replaced.fetch(source)) }
      end
      include = Erx::Generated.path('erlang/apps/erx/include', root: ROOT)
      Erx::FuzzWarm.compile(work: work, sources: sources, include: include)

      Open3.capture2e('gtimeout', '-k', '10', DEADLINE_SECONDS, ENV.fetch('ERX_ERL'), '-noshell', '-pa', work,
                      '-run', 'erx_bt_att_fuzz', 'run', seed.to_s, '-s', 'init', 'stop',
                      chdir: work, stdin_data: '')
    end
  end
end

if $PROGRAM_NAME == __FILE__
  seed = 1
  OptionParser.new { |flags| flags.on('--seed N', Integer) { |value| seed = value } }.parse!
  ErxBtAttFuzz.run(seed: seed)
end
