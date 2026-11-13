# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'minitest/autorun'
require 'open3'
require 'tmpdir'
require_relative '../fixtures/erlang_build'

# Runs test/erlang/erx_draw_core_tests.erl, the exploration of the draw
# protocol's pure core and its plan/2 cases, against erx_draw_core, the
# generated erx_draw_codec and erx_draw_image compiled on stock's emulator
# (ERX_ERL and ERX_ERLC, which make check supplies). Then each seeded fault
# of docs/design-display.md's "Verification and testing", applied to a copy
# of erx_draw_core, must fail the case named for it.
class ErxDrawCoreTest < Minitest::Test
  ROOT = File.expand_path('../..', __dir__)
  APPLICATIONS = %w[erx_display].freeze
  MODULE_SOURCE = 'erlang/apps/erx_display/src/erx_draw_core.erl'
  TESTS = %w[test/erlang/erx_draw_core_tests.erl].freeze
  DEADLINE_SECONDS = '600'

  Seed = Data.define(:fault, :anchor, :replacement, :catching_case)

  SEEDS = [
    Seed.new(fault: 'the quota check skipped',
             anchor: 'ok ?= check(Charged =< Quota, enomem),',
             replacement: 'ok ?= check(true, enomem),',
             catching_case: 'exploration_test_'),
    # Every plan_test_ case plans from a new connection with the window
    # this seed names, so its depths are those of the connection before the
    # write.
    Seed.new(fault: 'a plan that frames with the depths of the connection as it stood before the write',
             anchor: 'erx_draw_codec:decode(Bytes, depth_fun(State)),',
             replacement: 'erx_draw_codec:decode(Bytes, depth_fun(new(#{r => {0, 0, 4, 4}, chan => 16#48081828, ' \
                          'quota => #{pixels => 0, side => 1}}))),',
             catching_case: 'plan_test_')
  ].freeze

  def test_core_cases_pass_under_eunit
    output, status = eunit({})
    assert status.success?, output
    assert_match(/All \d+ tests passed/, output)
  end

  def test_each_seeded_fault_fails_its_case
    source = File.binread(File.join(ROOT, MODULE_SOURCE))
    SEEDS.each do |seed|
      assert_equal 1, source.scan(seed.anchor).size, "anchor for #{seed.fault} is not once in #{MODULE_SOURCE}"
    end
    runs = SEEDS.map do |seed|
      Thread.new { [seed, *eunit({ MODULE_SOURCE => source.sub(seed.anchor, seed.replacement) })] }
    end
    runs.map(&:value).each do |seed, output, status|
      refute status.success?, "#{seed.fault} passed every case:\n#{output}"
      assert_match(failed_case(seed.catching_case), output, "#{seed.catching_case} did not catch #{seed.fault}")
    end
  end

  private

  # EUnit names a plain case by its function and a generator's case by the fun inside it.
  def failed_case(name) = %r{#{Regexp.escape(name)}(/0-fun-\d+-)?\.\.\.(\[[^\]]*\] )?\*failed\*}

  # The cases' output and status, over the applications with the sources of replaced in place of the tree's.
  def eunit(replaced)
    Dir.mktmpdir('erx-draw-core-test') do |work|
      ErlangBuild.compile(work, applications: APPLICATIONS, tests: TESTS, replaced: replaced)
      Open3.capture2e('gtimeout', '-k', '10', DEADLINE_SECONDS, ENV.fetch('ERX_ERL'), '-noshell', '-pa', work,
                      '-eval', 'halt(case eunit:test(erx_draw_core_tests, [verbose]) of ok -> 0; _ -> 1 end)',
                      chdir: work, stdin_data: '')
    end
  end
end
