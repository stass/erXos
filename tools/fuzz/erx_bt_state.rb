# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true
# erx-gate: fuzz seeded deadline=300

require 'open3'
require 'optparse'
require 'tmpdir'
require_relative '../lib/erx/generated'
require_relative '../lib/erx/fuzz_warm'

# The fuzz target of the Bluetooth domain's stored state, erx_bt_state:decode/1, and of the
# development store's file names, erx_bt_state_file:generation/1
# (test/erlang/erx_bt_state_fuzz.erl), compiled from source and run alone on stock's
# emulator (ERX_ERL and ERX_ERLC, the oracle's), so it needs no hosted build. It runs
# the sources as they are, then, for each seeded fault, a copy of the module with the
# fault in place, which must fail with the verdict the fault breaks.
module ErxBtStateFuzz
  ROOT = File.expand_path('../..', __dir__)
  STATE = 'erlang/apps/erx_bt/src/erx_bt_state.erl'
  STATE_FILE = 'erlang/apps/erx_bt/src/erx_bt_state_file.erl'
  # The module the decoder calls to read an identity address.
  SMP_CRYPTO = 'erlang/apps/erx_bt/src/erx_smp_crypto.erl'
  FUZZ = 'test/erlang/erx_bt_state_fuzz.erl'
  # Each run is under this deadline, and tools/erx gives the whole runner 300.
  DEADLINE_SECONDS = '60'

  # A seeded fault: the module's anchor replaced, and the error term the run must fail
  # with, matched with its opening brace so one verdict is not read inside another.
  Fault = Data.define(:fault, :path, :anchor, :replacement, :verdict)

  FAULTS = [
    Fault.new(fault: 'the bond count read without its bound', path: STATE,
              anchor: 'Count =< ?ERX_BT_BONDS_MAX orelse refuse({too_many_bonds, Count}),',
              replacement: '',
              verdict: '{reencode_refused,'),
    Fault.new(fault: 'octets after the last bond taken', path: STATE,
              anchor: 'Left =:= trailing andalso Rest =/= <<>> andalso refuse(trailing),',
              replacement: '',
              verdict: '{reencoded_wrongly,'),
    Fault.new(fault: 'a file name with a leading zero read as a generation', path: STATE_FILE,
              anchor: '{[First | _] = Digits, Suffix} when First =/= $0, length(Digits) =< 18 ->',
              replacement: '{[_ | _] = Digits, Suffix} when length(Digits) =< 18 ->',
              verdict: '{renamed,')
  ].freeze

  module_function

  def run(seed:)
    Erx::Generated.ensure(root: ROOT)
    output, status = fuzz({}, seed: seed)
    abort(output) unless status.success? && output.match?(/^fuzz: \d+ rounds ok, /)
    FAULTS.each { |fault| run_fault(fault, seed: seed) }
    puts output[/^fuzz: .*$/]
    puts "erx_bt_state reads every stored state and erx_bt_state_file every name without a raise or an atom, and #{FAULTS.size} seeded " \
         'faults each fail their verdict'
  end

  def run_fault(fault, seed:)
    source = File.binread(File.join(ROOT, fault.path))
    raise "seed anchor for #{fault.fault} is not unique" unless source.scan(fault.anchor).size == 1

    output, status = fuzz({ fault.path => source.sub(fault.anchor) { fault.replacement } }, seed: seed)
    abort("#{fault.fault}: the fuzz run passed:\n#{output}") if status.success? || !output.include?(fault.verdict)
  end

  # In a directory of its own, which also takes the crash dump of a failed round; a
  # replaced module is compiled from its copy there.
  def fuzz(replaced, seed:)
    Dir.mktmpdir('erx-bt-state-fuzz') do |work|
      sources = [STATE, STATE_FILE, SMP_CRYPTO, FUZZ].map do |source|
        next File.join(ROOT, source) unless replaced.key?(source)

        File.join(work, File.basename(source)).tap { |path| File.binwrite(path, replaced.fetch(source)) }
      end
      include = Erx::Generated.path('erlang/apps/erx/include', root: ROOT)
      Erx::FuzzWarm.compile(work: work, sources: sources, include: include)

      Open3.capture2e('gtimeout', '-k', '10', DEADLINE_SECONDS, ENV.fetch('ERX_ERL'), '-noshell', '-pa', work,
                      '-run', 'erx_bt_state_fuzz', 'run', seed.to_s, '-s', 'init', 'stop',
                      chdir: work, stdin_data: '')
    end
  end
end

if $PROGRAM_NAME == __FILE__
  seed = 1
  OptionParser.new { |flags| flags.on('--seed N', Integer) { |value| seed = value } }.parse!
  ErxBtStateFuzz.run(seed: seed)
end
