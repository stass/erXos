# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'minitest/autorun'
require 'open3'
require 'tmpdir'
require_relative '../fixtures/erlang_build'

# The plans' one writer (docs/design-storage.md, "Durability"): test/erlang/erx_fat_plan_tests.erl
# runs on stock's emulator (ERX_ERL and ERX_ERLC, which make check supplies) against
# erx_fat_plan as it is and against each seeded fault below, where the named case must
# fail. The crash-state suite (test/host/erx_crash_states_test.rb) seeds a dropped
# flush against the volume's crash states too.
class ErxFatPlanTest < Minitest::Test
  ROOT = File.expand_path('../..', __dir__)
  CORE = 'erlang/apps/erx_fat/src/erx_fat_plan.erl'
  APPLICATIONS = %w[erx erx_fat].freeze
  TESTS = %w[test/erlang/erx_fat_plan_tests.erl].freeze
  RUN = 'run([{Sector, Bytes} | Rest], Sector, Count, Parts, RunMax) when Count < RunMax ->'

  Fault = Data.define(:name, :from, :to, :caught_by)

  # Each fault replaces one passage of erx_fat_plan; the case named in caught_by must fail.
  FAULTS = [
    Fault.new(name: 'a run that crosses a gap between sectors',
              from: RUN, to: RUN.sub('[{Sector, Bytes}', '[{_Gap, Bytes}'),
              caught_by: 'a_gap_ends_a_run_test'),
    Fault.new(name: "a run one sector past the window's largest request",
              from: RUN, to: RUN.sub('Count < RunMax', 'Count =< RunMax'),
              caught_by: 'runs_are_the_longest_contiguous_stretches_test'),
    Fault.new(name: 'a mirror written before the first FAT',
              from: 'Copy) when Copy < Count -> [First + Copy * Stride];',
              to: 'Copy) when Copy < Count -> [First + (Count - 1 - Copy) * Stride];',
              caught_by: 'mirrors_follow_the_first_fat_test'),
    Fault.new(name: "a step's flush dropped",
              from: "            case Flush() of\n", to: "            case erlang:phash2(Flush) >= 0 andalso ok of\n",
              caught_by: 'a_flush_follows_every_step_test'),
    Fault.new(name: "a round sorted by sector and image, so a sector named twice loses the plan's order",
              from: 'runs_written(lists:keysort(1, Round), RunMax, Write)',
              to: 'runs_written(lists:sort(Round), RunMax, Write)',
              caught_by: 'a_sector_named_twice_lands_its_last_image_test')
  ].freeze

  def test_the_cases_pass
    output, status = eunit(File.read(File.join(ROOT, CORE)))
    assert status.success?, output
    assert_match(/All \d+ tests passed/, output)
  end

  FAULTS.each_with_index do |fault, index|
    define_method(:"test_seeded_fault_#{index}_is_caught") do
      original = File.read(File.join(ROOT, CORE))
      assert_equal 1, original.scan(fault.from).size, "#{fault.name}: passage not found once"
      output, status = eunit(original.sub(fault.from) { fault.to })
      refute status.success?, "#{fault.name}: the tests passed\n#{output}"
      assert_match(/#{Regexp.escape(fault.caught_by)}.*?\*failed\*/m, output, fault.name)
    end
  end

  private

  # Compiles the plan as core_text, with erx_fat and the suite, and runs the suite.
  def eunit(core_text)
    Dir.mktmpdir('erx-fat-plan-test') do |work|
      ErlangBuild.compile(work, applications: APPLICATIONS, tests: TESTS, replaced: { CORE => core_text })
      Open3.capture2e('gtimeout', '-k', '10', '300', ENV.fetch('ERX_ERL'), '-noshell', '-pa', work,
                      '-eval', 'halt(case eunit:test(erx_fat_plan_tests, [verbose]) of ok -> 0; _ -> 1 end)',
                      chdir: work, stdin_data: '')
    end
  end
end
