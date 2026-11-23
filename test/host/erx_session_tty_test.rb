# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'fileutils'
require 'minitest/autorun'
require 'open3'
require 'tmpdir'
require_relative '../fixtures/erlang_build'
require_relative '../fixtures/line_editor'

# Runs test/erlang/erx_session_tty_tests.erl, the EUnit cases of a session's ttys
# (erx_session_tty), each driven by a terminal relay of its own, with the command shell
# on them and fake masters, against the ttys, erx_console and the erx_shell application
# compiled from source with warnings as errors on stock's emulator (ERX_ERL and ERX_ERLC,
# which make check supplies). The tree's group.erl is loaded in place of stock's, since
# only it asks its driver for input, which a relay's console needs (edit 72 of
# docs/design-runtime.md); `user` is erx_test_user, so no group runs stock's code when the
# tree's is loaded. The shell finds its commands through erx_shell's application file,
# copied beside the beams.
class ErxSessionTtyTest < Minitest::Test
  ROOT = File.expand_path('../..', __dir__)
  SHELL = File.join(ROOT, 'erlang/apps/erx_shell/src')
  # The applications the suite exercises, compiled whole (ErlangBuild), and the suite.
  APPLICATIONS = %w[erx erx_shell erx_session].freeze
  TESTS = (%w[test/erlang/erx_test_user.erl test/erlang/erx_session_tty_tests.erl] + LineEditor::SOURCES).freeze
  EVAL = 'logger:set_primary_config(level, none), ' \
         "#{LineEditor::LOAD}" \
         'halt(case eunit:test(erx_session_tty_tests, [verbose]) of ok -> 0; _ -> 1 end).'

  def test_relay_cases_pass_under_eunit
    Dir.mktmpdir('erx-session-tty-test') do |work|
      ErlangBuild.compile(work, applications: APPLICATIONS, tests: TESTS)
      FileUtils.cp(File.join(SHELL, 'erx_shell.app.src'), File.join(work, 'erx_shell.app'))

      output, status = Open3.capture2e('gtimeout', '-k', '10', '120', ENV.fetch('ERX_ERL'), '-noshell',
                                       '-user', 'erx_test_user', '-pa', work, '-eval', EVAL,
                                       chdir: work, stdin_data: '')
      assert status.success?, output
      assert_match(/Test passed\.|\d+ tests passed/, output)
    end
  end
end
