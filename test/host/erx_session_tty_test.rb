# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'fileutils'
require 'minitest/autorun'
require 'open3'
require 'tmpdir'
require_relative '../fixtures/erlang_build'

# Runs test/erlang/erx_session_tty_tests.erl, the EUnit cases of the session's tty relay
# (erx_session_tty) with the command shell on it and a fake master, against the relay,
# erx_console and the erx_shell application compiled from source with warnings as errors
# on stock's emulator (ERX_ERL and ERX_ERLC, which make check supplies). The shell finds
# its commands through erx_shell's application file, copied beside the beams.
class ErxSessionTtyTest < Minitest::Test
  ROOT = File.expand_path('../..', __dir__)
  SHELL = File.join(ROOT, 'erlang/apps/erx_shell/src')
  # The applications the suite exercises, compiled whole (ErlangBuild), and the suite.
  APPLICATIONS = %w[erx erx_shell erx_session].freeze
  TESTS = %w[test/erlang/erx_session_tty_tests.erl].freeze

  def test_relay_cases_pass_under_eunit
    Dir.mktmpdir('erx-session-tty-test') do |work|
      ErlangBuild.compile(work, applications: APPLICATIONS, tests: TESTS)
      FileUtils.cp(File.join(SHELL, 'erx_shell.app.src'), File.join(work, 'erx_shell.app'))

      output, status = Open3.capture2e('gtimeout', '-k', '10', '120', ENV.fetch('ERX_ERL'), '-noshell', '-pa', work,
                                       '-eval', 'halt(case eunit:test(erx_session_tty_tests, [verbose]) of ok -> 0; _ -> 1 end).',
                                       chdir: work, stdin_data: '')
      assert status.success?, output
      assert_match(/Test passed\.|All \d+ tests passed/, output)
    end
  end
end
