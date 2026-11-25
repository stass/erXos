# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'minitest/autorun'
require_relative '../../tools/lib/erx/ble_board_check'

# The verdicts of tools/ble_board_check.rb over blew's logs. The fixtures are cut
# from the recorded run of a Pi 4 (scan, connect and discover, write, read); the
# crowded scan has the shapes a busy room adds.
class BleBoardCheckTest < Minitest::Test
  Check = Erx::BleBoardCheck
  BOARD = 'F8A0E70B-141F-2388-9DA9-CCFD586437E0'
  SPARE = 'BCAC47AC-9213-8650-88C3-EF7CD155F7D1'

  def fixture(name) = File.read(File.join(__dir__, '../fixtures/ble_board_check', name))

  def run_of(output, exit_code) = Check::Run.new(output: output, exit_code: exit_code)

  def step(name) = Check.steps(BOARD).find { |step| step.name == name }

  def outcome_of(name, output, exit_code) = Check.step_outcome(step(name), run_of(output, exit_code))

  def scan(output, exit_code = 0, name: 'erxos') = Check.scan_result(run_of(output, exit_code), name)

  def test_the_scan_passes_on_one_device_with_the_exact_name
    result = scan(fixture('scan_board.log'))
    assert_equal :passed, result.outcome.verdict
    assert_equal BOARD, result.id
  end

  def test_the_scan_matches_the_whole_name_not_a_part
    assert_equal BOARD, scan(fixture('scan_crowd.log')).id
    assert_equal SPARE, scan(fixture('scan_crowd.log'), name: 'erxos spare').id
  end

  def test_the_scan_fails_when_no_device_advertises_the_name
    result = scan(fixture('scan_crowd.log'), name: 'erx')
    assert_equal :failed, result.outcome.verdict
    assert_nil result.id
    assert_equal :failed, scan('', 2).outcome.verdict
  end

  def test_the_scan_is_unknown_when_two_devices_advertise_the_name
    twice = fixture('scan_board.log') + fixture('scan_board.log').sub('F8', 'F9')
    assert_equal :unknown, scan(twice).outcome.verdict
  end

  # blew's scan turns Bluetooth being unavailable into 5, which says nothing of the board.
  def test_the_scan_is_unknown_when_blew_could_not_scan
    [3, 4, 5, 6, 127, nil].each do |code|
      assert_equal :unknown, scan('Error: Bluetooth is off', code).outcome.verdict, code.inspect
      assert_equal :unknown, scan(fixture('scan_board.log'), code).outcome.verdict, code.inspect
    end
  end

  def test_a_name_with_an_escaped_quote_is_read_whole
    line = "id=#{BOARD} name=\"say \\\"hi\\\"\" rssi=-40 services=\"\"\n"
    assert_equal BOARD, scan(line, name: 'say "hi"').id
  end

  def test_a_backslash_in_a_name_is_kept
    assert_equal BOARD, scan("id=#{BOARD} name=\"a\\b c\" rssi=-40 services=\"\"\n", name: 'a\b c').id
  end

  def test_a_name_that_forges_a_scan_line_leaves_the_scan_unknown
    forged = "id=#{SPARE} name=\"x\nid=#{BOARD} name=erxos\" rssi=-40 services=\"\"\n"
    result = scan(forged)
    assert_equal :unknown, result.outcome.verdict
    assert_nil result.id
  end

  def test_an_identifier_that_is_no_uuid_reaches_no_script
    assert_raises(Erx::Error) { Check.steps('F8A0E70B; write') }
  end

  def test_discovery_passes_on_a_table_with_nus
    assert_equal :passed, outcome_of('connect and discover', fixture('discover_nus.log'), 0).verdict
  end

  def test_discovery_fails_on_a_table_without_nus
    assert_equal :failed, outcome_of('connect and discover', "type=service uuid=180F\n", 0).verdict
  end

  def test_the_write_is_unknown_when_no_handler_answered
    outcome = outcome_of('write NUS RX', fixture('write_unlikely.log'), 5)
    assert_equal :unknown, outcome.verdict
    assert_equal 'Unlikely Error: no handler answered', outcome.detail
  end

  def test_the_write_passes_when_an_app_takes_it
    assert_equal :passed, outcome_of('write NUS RX', '', 0).verdict
  end

  def test_the_write_fails_on_any_other_refusal
    output = "Error: Write failed: Writing is not permitted.\nError: exit code 5\n"
    assert_equal :failed, outcome_of('write NUS RX', output, 1).verdict
  end

  def test_the_read_passes_when_refused
    assert_equal :passed, outcome_of('read NUS RX, refused', fixture('read_refused.log'), 1).verdict
  end

  def test_the_read_fails_when_it_returns_a_value
    assert_equal :failed, outcome_of('read NUS RX, refused', "00\n", 0).verdict
  end

  def test_the_steps_are_unknown_on_the_exits_that_say_nothing_about_the_board
    [2, 3, 4, 6, 127, 124, 1, nil].each do |code|
      ['connect and discover', 'write NUS RX', 'read NUS RX, refused'].each do |name|
        assert_equal :unknown, outcome_of(name, fixture('discover_nus.log'), code).verdict, "#{name} #{code.inspect}"
      end
    end
  end

  # ArgumentParser prints the code of the failed command and exits 1; the line decides
  # then, and never over a killed run or another exit.
  def test_the_last_exit_code_line_decides_when_blew_exited_1
    timed_out = run_of("connecting\nError: exit code 4\n", 1)
    assert_equal 4, Check.blew_exit(timed_out)
    assert_equal :unknown, Check.step_outcome(step('read NUS RX, refused'), timed_out).verdict
    assert_equal 5, Check.blew_exit(run_of(fixture('read_refused.log'), 1))
    assert_nil Check.blew_exit(run_of(fixture('read_refused.log'), nil))
    assert_equal 0, Check.blew_exit(run_of("Error: exit code 08\n", 0))
  end

  # What bleuart's line answers a session, in the shape of the Pi 4's: the tty echoes
  # each typed line, rc redraws it after the prompt, and the answer follows.
  SHELL_ROWS = "{group,{erx_shell,server,[{erx_shell_runner,\r\n"
  def typed(command) = "#{command}\r\n\e[A\e[J% #{command}\r\n"

  def session_output(shells: 1, display: true, interrupted: true)
    ps = "#{typed('ps -o comm')}COMMAND\r\ninit\r\n#{SHELL_ROWS * shells}% "
    top = "#{typed(Check::TOP)}#{display ? "\e[H\e[2Jrun queue: 0\r\n" : ''}"
    top += interrupted ? "^C\r\n% #{typed('echo top^done')}topdone\r\n% " : ''
    "rc: the command shell; exit ends it\r\n% #{typed('echo ble^uart')}bleuart\r\n% #{ps}#{top}"
  end

  def reconnection_output(shells: 1)
    "% #{typed('echo fresh^prompt')}freshprompt\r\n% #{typed('ps -o comm')}COMMAND\r\n#{SHELL_ROWS * shells}% "
  end

  def test_the_read_passes_when_blew_refuses_it_on_the_declared_properties
    output = "Error: Read failed: characteristic #{Check::NUS_RX} is not readable (properties: write, writeNoResp)\n"
    assert_equal :passed, outcome_of('read NUS RX, refused', output, 5).verdict
  end

  def bleuart(first, second, first_code: 0, second_code: 0)
    Check.bleuart_outcomes(run_of(first, first_code), run_of(second, second_code)).to_h.transform_values(&:verdict)
  end

  def test_a_bleuart_session_that_answers_everything_passes
    assert_equal({ 'bleuart prompt and echo' => :passed, 'bleuart ps' => :passed, 'bleuart top, Ctrl-C' => :passed,
                   'bleuart reconnection' => :passed }, bleuart(session_output, reconnection_output))
  end

  def test_top_fails_without_its_display_or_without_the_shell_after_ctrl_c
    assert_equal :failed, bleuart(session_output(display: false), reconnection_output)['bleuart top, Ctrl-C']
    assert_equal :failed, bleuart(session_output(interrupted: false), reconnection_output)['bleuart top, Ctrl-C']
  end

  def test_the_tty_echo_of_a_command_is_not_its_answer
    echoed_only = "% #{typed('echo ble^uart')}% "
    assert_equal :failed, bleuart(echoed_only, reconnection_output)['bleuart prompt and echo']
  end

  def test_ps_fails_without_its_header_or_a_shell
    assert_equal :failed, bleuart(session_output.sub("COMMAND\r\n", ''), reconnection_output)['bleuart ps']
    assert_equal :failed, bleuart(session_output(shells: 0), reconnection_output)['bleuart ps']
  end

  # The first connection's shell outlived it, or the reconnection got no prompt.
  def test_the_reconnection_fails_on_a_shell_left_behind_or_no_prompt
    assert_equal :failed, bleuart(session_output, reconnection_output(shells: 2))['bleuart reconnection']
    assert_equal :failed, bleuart(session_output, 'connected')['bleuart reconnection']
  end

  def test_a_session_blew_did_not_finish_is_unknown
    [2, 3, 4, 6, nil].each do |code|
      verdicts = bleuart(session_output, reconnection_output, first_code: code, second_code: code)
      assert_equal [:unknown], verdicts.values.uniq, code.inspect
    end
  end

  def test_an_identifier_that_is_no_uuid_reaches_no_nus_session
    assert_raises(Erx::Error) { Check.nus_argv('F8A0E70B; x', linger: 5) }
  end

  def test_the_exit_of_a_checklist
    passed = Check.outcome(:passed, '')
    assert_equal 0, Check.script_exit([passed, Check.outcome(:unknown, '')])
    assert_equal 1, Check.script_exit([passed, Check.outcome(:failed, '')])
    assert_equal 3, Check.script_exit([Check.outcome(:unknown, '')])
  end
end
