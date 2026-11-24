# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'minitest/autorun'
require 'open3'
require 'tmpdir'
require_relative '../fixtures/erlang_build'
require_relative '../fixtures/line_editor'

# Runs the EUnit cases of the console as the master of a session's tty: the pure core
# against arbitrary terms and against the tty's own core (test/erlang/
# erx_tty_master_tests.erl), the Ctrl-G rule and the menu's core (test/erlang/
# erx_console_keys_tests.erl, erx_console_menu_tests.erl), and the console end to end
# behind a console facet
# (test/erlang/erx_console_master_tests.erl), compiled from source with warnings as
# errors on stock's emulator (ERX_ERL and ERX_ERLC, which make check supplies), with the
# tree's group.erl and its edlin loaded in place of stock's, so the system shell reads
# its line as a system domain's does. `user` is erx_test_user, so no group runs stock's
# code when the tree's is loaded. The seeded faults (docs/design-live.md, "Lost input",
# Verification): a console that answers a loss on the system line after the next input,
# one that keeps a character's leading byte across a loss, an escape state kept across a
# loss, by the console or by erx_console_keys:lost/1, and for a pipe's console, its tty
# given ICRNL, its driver answered at once whatever the tty's room, and the menu run.
class ErxConsoleMasterTest < Minitest::Test
  APPLICATIONS = %w[erx erx_files erx_domain erx_session].freeze
  TESTS = %w[test/erlang/erx_test_user.erl test/erlang/erx_tty_master_tests.erl
             test/erlang/erx_console_keys_tests.erl test/erlang/erx_console_menu_tests.erl
             test/erlang/erx_console_master_tests.erl].freeze
  CONSOLE = 'erlang/apps/erx/src/erx_console.erl'
  KEYS = 'erlang/apps/erx/src/erx_console_keys.erl'
  # The console's input clause and its loss clause, and the same with the loss held
  # until the next input has been delivered.
  TAKEN = '{noreply, serve(typed(Bytes, unanswered(State)))};'
  LATE_TAKEN = '{noreply, serve(case erase(seeded_loss) of ' \
               'true -> driver_lost(typed(Bytes, unanswered(State))); ' \
               'undefined -> typed(Bytes, unanswered(State)) end)};'
  LOST = '{noreply, serve(driver_lost(unanswered(State)))};'
  HELD_LOST = 'put(seeded_loss, true), {noreply, serve(unanswered(State))};'
  KEYS_LOST = 'State = State0#state{keys = erx_console_keys:lost(Keys)},'
  KEPT_KEYS = 'State = State0#state{keys = Keys},'
  # The loss's read drops the bytes held for the group, and the same keeping them.
  CUT = "damage(Group, State0 = #state{asks = Asks}) ->\n    State = drop_held(Group, State0),"
  KEPT_CUT = "damage(Group, State0 = #state{asks = Asks}) ->\n    State = State0,"
  # A pipe's tty set as a terminal's, for CR; a pipe answered at once whatever its
  # tty's room; and a pipe's console that runs the menu.
  PIPE_TERMIOS = '(erx_tty:termios(erx_tty:new()))#{iflag := [], oflag := [], lflag := []}'
  PIPE_ICRNL = '(erx_tty:termios(erx_tty:new()))#{iflag := [icrnl], oflag := [], lflag := []}'
  PIPE_ROOM = 'true -> min(byte_size(Unread), erx_tty:input_room(Tty));'
  NO_ROOM = 'true -> byte_size(Unread);'
  PIPE_MENU = 'menu = Terminal andalso maps:get(menu, Config, Role =:= system),'
  ANY_MENU = 'menu = maps:get(menu, Config, Role =:= system),'

  def test_master_cases_pass_under_eunit
    output, status = eunit
    assert status.success?, output
    assert_match(/All \d+ tests passed/, output)
  end

  def test_a_loss_answered_after_the_next_input_fails
    assert_seed_fails({ CONSOLE => { TAKEN => LATE_TAKEN, LOST => HELD_LOST } },
                      'erx_console_master_tests:a_loss_runs_no_system_line/0', also: 'sys:abc')
  end

  def test_a_cut_character_kept_across_a_loss_fails
    assert_seed_fails({ CONSOLE => { CUT => KEPT_CUT } }, 'erx_console_master_tests:a_loss_drops_a_cut_character/0')
  end

  def test_a_console_that_keeps_the_escape_state_across_a_loss_fails
    assert_seed_fails({ CONSOLE => { KEYS_LOST => KEPT_KEYS } },
                      'erx_console_master_tests:a_loss_ends_a_terminal_reply/0')
  end

  def test_a_pipe_read_with_icrnl_fails
    assert_seed_fails({ CONSOLE => { PIPE_TERMIOS => PIPE_ICRNL } }, /erx_console_master_tests: pipe\.\.\.\*failed\*/,
                      also: '{read,"\\n"}')
  end

  def test_a_pipe_answered_at_once_fails
    assert_seed_fails({ CONSOLE => { PIPE_ROOM => NO_ROOM } }, /erx_console_master_tests: pipe\.\.\.\*failed\*/,
                      also: 'not_taken')
  end

  def test_a_pipe_with_the_menu_fails
    assert_seed_fails({ CONSOLE => { PIPE_MENU => ANY_MENU } }, /erx_console_master_tests: pipe\.\.\.\*failed\*/)
  end

  def test_an_escape_state_kept_across_a_loss_fails
    assert_seed_fails({ KEYS => { 'lost(_State) -> ground.' => 'lost(State) -> State.' } },
                      /a_loss_ends_a_string_test\S*\.\.\.\*failed\*/)
  end

  private

  # The cases, with each anchor of each file replaced, must fail where Where, a text or a
  # pattern, says, and show Also, when given, in the failure.
  def assert_seed_fails(seeds, where, also: nil)
    replaced = seeds.to_h do |path, edits|
      source = File.binread(File.join(ErlangBuild::ROOT, path))
      [path, edits.reduce(source) do |text, (anchor, replacement)|
        assert_equal 1, text.scan(anchor).size, "#{path} no longer holds #{anchor.inspect} once"
        text.sub(anchor) { replacement }
      end]
    end
    output, status = eunit(replaced: replaced)
    refute status.success?, output
    assert_match(where.is_a?(Regexp) ? where : /#{Regexp.escape(where)}/, output)
    assert_includes output, also if also
  end

  def eunit(replaced: {})
    Dir.mktmpdir('erx-console-master-test') do |work|
      ErlangBuild.compile(work, applications: APPLICATIONS, tests: TESTS + LineEditor::SOURCES, replaced: replaced)
      eval = "#{LineEditor::LOAD}" \
             'halt(case eunit:test([erx_tty_master_tests, erx_console_keys_tests, erx_console_menu_tests, ' \
             'erx_console_master_tests], [verbose]) of ok -> 0; _ -> 1 end).'
      Open3.capture2e('gtimeout', '-k', '10', '180', ENV.fetch('ERX_ERL'), '-noshell', '-user', 'erx_test_user',
                      '-pa', work, '-eval', eval, chdir: work, stdin_data: '')
    end
  end
end
