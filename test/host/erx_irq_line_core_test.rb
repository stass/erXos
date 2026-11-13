# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'minitest/autorun'
require 'open3'
require 'tmpdir'

# Runs test/erlang/erx_irq_line_core_tests.erl, the EUnit cases of the shared line owner's
# state machine, against erx_irq_line_core compiled from source on stock's emulator
# (ERX_ERL and ERX_ERLC, which make check supplies). Then each seeded fault of the
# erx_irq_line_core row of docs/design-shared-devices.md's Verification table, applied to
# a copy of the module, must fail every case named for it, which shows those cases run
# the code the fault breaks.
class ErxIrqLineCoreTest < Minitest::Test
  ROOT = File.expand_path('../..', __dir__)
  MODULE_SOURCE = File.join(ROOT, 'erlang/apps/erx/src/erx_irq_line_core.erl')
  TESTS_SOURCE = File.join(ROOT, 'test/erlang/erx_irq_line_core_tests.erl')
  EXHAUSTIVE = 'every_sequence_of_eight_events_over_four_members_test'

  Seed = Data.define(:fault, :anchor, :replacement, :catching_cases)

  SEEDS = [
    Seed.new(fault: 'an acknowledgement at the first done',
             anchor: '        Rest -> {[], Core#core{phase = {round, Rest, Again}}}',
             replacement: '        Rest -> {[ack], Core#core{phase = {round, Rest, Again}}}',
             catching_cases: [EXHAUSTIVE, 'the_line_is_acknowledged_after_the_last_answer_test']),
    Seed.new(fault: 'Again dropped, so a firing during a round tells no one',
             anchor: "step(fire, #core{phase = {round, Waiting, _}} = Core) ->\n" \
                     '    {[], Core#core{phase = {round, Waiting, true}}};',
             replacement: "step(fire, #core{phase = {round, _, _}} = Core) ->\n    {[], Core};",
             catching_cases: [EXHAUSTIVE, 'a_firing_after_an_answer_tells_every_member_again_test']),
    Seed.new(fault: 'a down that leaves W unchanged',
             anchor: '        {round, Waiting, Again} -> answered(M, Waiting, Again, Left);',
             replacement: '        {round, _, _} -> {[], Left};',
             catching_cases: [EXHAUSTIVE, 'a_join_then_its_down_in_a_round_acknowledges_test']),
    Seed.new(fault: 'a join in held that does not add its member, so its down leaves the line masked',
             anchor: '    Joined = Core#core{members = Members#{M => {Pid, Dev}}},' "\n" \
                     '    {[{notify, Pid, Dev}], Joined#core{phase = {round, [M], false}}};',
             replacement: '    {[{notify, Pid, Dev}], Core};',
             catching_cases: [EXHAUSTIVE, 'a_join_then_its_down_in_held_acknowledges_test']),
    Seed.new(fault: 'a firing with no member acknowledged at once',
             anchor: '    {[], Core#core{phase = held}};',
             replacement: '    {[ack], Core#core{phase = idle}};',
             catching_cases: [EXHAUSTIVE, 'a_firing_with_no_member_holds_the_line_test'])
  ].freeze

  def test_core_cases_pass_under_eunit
    output, status = eunit(File.binread(MODULE_SOURCE), warnings_as_errors: true)
    assert status.success?, output
    assert_match(/All \d+ tests passed/, output)
  end

  def test_each_seeded_fault_fails_its_cases
    source = File.binread(MODULE_SOURCE)
    SEEDS.each do |seed|
      assert_equal 1, source.scan(seed.anchor).size, "no single anchor for #{seed.fault} in #{MODULE_SOURCE}"
      output, status = eunit(source.sub(seed.anchor, seed.replacement), warnings_as_errors: false)
      refute status.success?, "#{seed.fault} passed every case:\n#{output}"
      seed.catching_cases.each do |name|
        assert_match(/#{name}\.\.\.(\[[^\]]*\] )?\*failed\*/, output, "#{name} did not catch #{seed.fault}")
      end
    end
  end

  private

  def eunit(module_text, warnings_as_errors:)
    Dir.mktmpdir('erx-irq-line-core-test') do |work|
      module_path = File.join(work, 'erx_irq_line_core.erl')
      File.binwrite(module_path, module_text)
      flags = warnings_as_errors ? ['-Werror'] : []
      output, status = Open3.capture2e(ENV.fetch('ERX_ERLC'), *flags, '-o', work, module_path, TESTS_SOURCE,
                                       stdin_data: '')
      return [output, status] unless status.success?

      Open3.capture2e('gtimeout', '-k', '10', '120', ENV.fetch('ERX_ERL'), '-noshell', '-pa', work,
                      '-eval', 'halt(case eunit:test(erx_irq_line_core_tests, [verbose]) of ok -> 0; _ -> 1 end)',
                      chdir: work, stdin_data: '')
    end
  end
end
