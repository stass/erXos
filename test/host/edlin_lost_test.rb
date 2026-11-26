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

  # The seeded faults of the group's monitor of a requester: a request that is not dropped
  # when its requester ends (the current one, one set aside), and an end that does not hold
  # the loss of a damaged read.
  def test_a_current_request_that_outlives_its_requester_fails
    seeded("    pop_state(error, Data);\n%% The requester of a request set aside", "    keep_state_and_data;\n%% The requester of a request set aside",
           'a_group_drops_the_current_request_of_an_ended_requester_test')
  end

  def test_a_set_aside_request_that_outlives_its_requester_fails
    seeded('Set =/= Mref end, Queue)', 'true end, Queue)', 'a_group_drops_a_set_aside_request_of_an_ended_requester_test')
  end

  def test_a_dead_process_request_that_is_not_dropped_fails
    seeded('case node(From) =:= node() andalso not is_process_alive(From) of', 'case false of',
           'a_group_drops_the_request_of_a_dead_process_test')
  end

  def test_an_ended_requester_that_drops_the_loss_fails
    seeded("    pop_state(error, Data);\n%% The requester of a request set aside", "    pop_state(interrupted, Data);\n%% The requester of a request set aside",
           'a_group_holds_the_loss_of_a_request_whose_requester_ended_test')
  end

  private

  def seeded(old, new, test)
    source = File.binread(File.join(OtpEunit::ROOT, GROUP))
    assert_equal 1, source.scan(old).size, "#{GROUP} no longer holds #{old.inspect} once"
    result = run_cases(replaced: { GROUP => source.sub(old) { new } })
    refute result.passed, result.output
    assert_match(/#{test}\S*\.\.\.\*failed\*/, result.output)
  end

  def run_cases(replaced: {})
    Dir.mktmpdir('erx-edlin') do |work|
      OtpEunit.run(work, sources: LineEditor::SOURCES, test: TESTS, replaced: replaced)
    end
  end
end
