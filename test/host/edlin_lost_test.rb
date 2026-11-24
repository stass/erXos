# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'minitest/autorun'
require 'tmpdir'
require_relative '../fixtures/line_editor'
require_relative '../fixtures/otp_eunit'

# Runs the EUnit cases of test/erlang/edlin_lost_tests.erl against the tree's line editor
# and group, otp/lib/stdlib/src/edlin.erl and edlin_key.erl and otp/lib/kernel/src/group.erl,
# loaded over stock's. The seeded fault: a stray answer that damages the unfinished
# requests but is not held for the next one.
class EdlinLostTest < Minitest::Test
  TESTS = 'test/erlang/edlin_lost_tests.erl'
  GROUP = 'otp/lib/kernel/src/group.erl'
  STRAY_HELD = '    {keep_state, lose(Data#state{ held_loss = true })};'

  def test_the_trees_editor_and_group_run_no_line_that_lost_input
    result = run_cases
    assert result.passed, result.output
  end

  def test_a_stray_loss_not_held_fails
    source = File.binread(File.join(OtpEunit::ROOT, GROUP))
    assert_equal 1, source.scan(STRAY_HELD).size, "#{GROUP} no longer holds #{STRAY_HELD.inspect} once"
    result = run_cases(replaced: { GROUP => source.sub(STRAY_HELD, '    {keep_state, lose(Data)};') })
    refute result.passed, result.output
    assert_match(/a_group_holds_a_stray_loss_past_the_users_discard_test\S*\.\.\.\*failed\*/, result.output)
  end

  private

  def run_cases(replaced: {})
    Dir.mktmpdir('erx-edlin') do |work|
      OtpEunit.run(work, sources: LineEditor::SOURCES, test: TESTS, replaced: replaced)
    end
  end
end
