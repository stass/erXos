# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true
# erx-gate: fuzz seeded deadline=300

require 'open3'
require 'optparse'
require 'tmpdir'
require_relative '../lib/erx/generated'
require_relative '../lib/erx/fuzz_warm'

# The fuzz target of the Bluetooth Security Manager channel, erx_smp:decode/1 and the
# responder that takes what it decodes, erx_smp_core:step/2
# (test/erlang/erx_bt_smp_fuzz.erl), compiled from source and run alone on stock's
# emulator (ERX_ERL and ERX_ERLC, the oracle's), so it needs no hosted build. It runs
# the sources as they are, then, for each seeded fault, a copy of the module with the
# fault in place, which must fail with the verdict the fault breaks.
module ErxBtSmpFuzz
  ROOT = File.expand_path('../..', __dir__)
  SMP = 'erlang/apps/erx_bt/src/erx_smp.erl'
  CORE = 'erlang/apps/erx_bt/src/erx_smp_core.erl'
  CRYPTO = 'erlang/apps/erx_bt/src/erx_smp_crypto.erl'
  FUZZ = 'test/erlang/erx_bt_smp_fuzz.erl'
  # Each run is under this deadline, and tools/erx gives the whole runner 300.
  DEADLINE_SECONDS = '60'

  # A seeded fault: the module's anchor replaced, and the error term the run must fail
  # with, matched with its opening brace so one verdict is not read inside another.
  Fault = Data.define(:fault, :module_path, :anchor, :replacement, :verdict)

  FAULTS = [
    Fault.new(fault: 'a Pairing Confirm taken with octets after its value',
              module_path: SMP,
              anchor: 'data(?ERX_SMP_CODE_PAIRING_CONFIRM, <<Value:16/binary>>) ->',
              replacement: 'data(?ERX_SMP_CODE_PAIRING_CONFIRM, <<Value:16/binary, _/binary>>) ->',
              verdict: '{length_disagrees,'),
    Fault.new(fault: "a public key's coordinates kept in the wire's octet order",
              module_path: SMP,
              anchor: '{pairing_public_key, {reversed(X), reversed(Y)}};',
              replacement: '{pairing_public_key, {X, Y}};',
              verdict: '{decoded_wrongly,'),
    Fault.new(fault: 'the curve check removed, so an off-curve key reaches the key agreement',
              module_path: CORE,
              anchor: 'require(erx_smp_crypto:on_curve(Key), ?ERX_SMP_REASON_DHKEY_CHECK_FAILED, dhkey),',
              replacement: '',
              verdict: '{core_raised,')
  ].freeze

  module_function

  def run(seed:)
    Erx::Generated.ensure(root: ROOT)
    output, status = fuzz({}, seed: seed)
    abort(output) unless status.success? && output.match?(/^fuzz: \d+ rounds ok, /)
    FAULTS.each { |fault| run_fault(fault, seed: seed) }
    puts output[/^fuzz: .*$/]
    puts "erx_smp reads every Security Manager PDU, and erx_smp_core takes it, without a raise or an " \
         "atom, and #{FAULTS.size} seeded faults each fail their verdict"
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
    Dir.mktmpdir('erx-bt-smp-fuzz') do |work|
      sources = [SMP, CORE, CRYPTO, FUZZ].map do |source|
        next File.join(ROOT, source) unless replaced.key?(source)

        File.join(work, File.basename(source)).tap { |path| File.binwrite(path, replaced.fetch(source)) }
      end
      include = Erx::Generated.path('erlang/apps/erx/include', root: ROOT)
      Erx::FuzzWarm.compile(work: work, sources: sources, include: include)

      Open3.capture2e('gtimeout', '-k', '10', DEADLINE_SECONDS, ENV.fetch('ERX_ERL'), '-noshell', '-pa', work,
                      '-run', 'erx_bt_smp_fuzz', 'run', seed.to_s, '-s', 'init', 'stop',
                      chdir: work, stdin_data: '')
    end
  end
end

if $PROGRAM_NAME == __FILE__
  seed = 1
  OptionParser.new { |flags| flags.on('--seed N', Integer) { |value| seed = value } }.parse!
  ErxBtSmpFuzz.run(seed: seed)
end
