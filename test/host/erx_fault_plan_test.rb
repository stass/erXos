# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'minitest/autorun'
require 'open3'
require 'tmpdir'
require_relative '../fixtures/erlang_build'

# Runs test/erlang/erx_fault_plan_tests.erl, the cases of the stand-ins' one fault
# vocabulary (docs/design-recovery.md, "Fault injection and tests", layer 2), on stock's
# emulator (ERX_ERL and ERX_ERLC, which make check supplies), against the module as it is
# and against each seeded fault, where the named case must fail.
class ErxFaultPlanTest < Minitest::Test
  PLAN = 'test/erlang/erx_fault_plan.erl'
  TESTS = [PLAN, 'test/erlang/erx_fault_plan_tests.erl'].freeze
  DEADLINE_SECONDS = '120'

  Seed = Data.define(:fault, :anchor, :replacement, :catching_case)

  SEEDS = [
    Seed.new(fault: 'a taken rule left in the plan',
             anchor: '{Before, [{_Match, Fault} | After]} -> {Fault, Counted#{rules := Before ++ After}}',
             replacement: '{_Before, [{_Match, Fault} | _After]} -> {Fault, Counted}',
             catching_case: 'each_fault_is_met_once_by_the_next_exchange_of_its_kind_test'),
    Seed.new(fault: 'the Nth exchange counted from zero',
             anchor: 'N = maps:get(Kind, Seen, 0) + 1,',
             replacement: 'N = maps:get(Kind, Seen, 0),',
             catching_case: 'the_nth_match_waits_for_the_nth_exchange_of_its_kind_test'),
    Seed.new(fault: 'a device gone for one exchange only',
             anchor: '{gone, Counted#{rules := Before ++ After, gone := true}}',
             replacement: '{gone, Counted#{rules := Before ++ After}}',
             catching_case: 'gone_lasts_for_every_later_exchange_of_any_kind_test')
  ].freeze

  def test_the_cases_pass
    output, status = run_cases({})
    assert status.success?, output
    assert_match(/All \d+ tests passed/, output)
  end

  def test_each_seeded_fault_fails_its_case
    source = File.binread(File.join(ErlangBuild::ROOT, PLAN))
    SEEDS.each do |seed|
      assert_equal 1, source.scan(seed.anchor).size, "seed anchor for #{seed.fault} is not unique"
      output, status = run_cases({ PLAN => source.sub(seed.anchor) { seed.replacement } })
      refute status.success?, "#{seed.fault}: the cases passed"
      assert_match(/#{Regexp.escape(seed.catching_case)}[^\n]*\*failed\*/, output, seed.fault)
    end
  end

  private

  def run_cases(replaced)
    Dir.mktmpdir('erx-fault-plan-test') do |work|
      ErlangBuild.compile(work, applications: [], tests: TESTS, replaced: replaced)
      Open3.capture2e('gtimeout', '-k', '10', DEADLINE_SECONDS, ENV.fetch('ERX_ERL'), '-noshell', '-pa', work,
                      '-eval', 'halt(case eunit:test(erx_fault_plan_tests, [verbose]) of ok -> 0; _ -> 1 end)',
                      chdir: work, stdin_data: '')
    end
  end
end
