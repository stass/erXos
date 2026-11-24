# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'minitest/autorun'
require 'open3'
require 'tmpdir'
require_relative '../fixtures/erlang_build'

# Runs test/erlang/erx_tty_line_tests.erl, the EUnit cases of the session's line to the SSH
# domain (docs/design-ssh.md, "Sessions, ttys and shells"; docs/design-system.md, "A session's
# lines"): its mint, the shape checks of open_tty through its facet, a channel of a third
# domain, the channel limit, the exit report and the bound of a request, and the job relay's
# protocol (erx_ssh_job_core), explored exhaustively, and the relay itself (erx_ssh_job)
# running the real rc, compiled from source with warnings as errors on stock's emulator
# (ERX_ERL and ERX_ERLC, which make check supplies). The export table, the session's
# connection, the opening and the tty opener are the test's stand-ins.
class ErxSshLineTest < Minitest::Test
  APPLICATIONS = %w[erx erx_shell erx_tty_line].freeze
  TESTS = %w[test/erlang/stand_in/erx_inspector.erl test/erlang/erx_line_bound.erl
              test/erlang/erx_tty_line_tests.erl test/erlang/erx_ssh_job_core_tests.erl
              test/erlang/erx_ssh_job_tests.erl].freeze

  def test_line_cases_pass_under_eunit
    Dir.mktmpdir('erx-ssh-line-test') do |work|
      ErlangBuild.compile(work, applications: APPLICATIONS, tests: TESTS)
      output, status = Open3.capture2e('gtimeout', '-k', '10', '300', ENV.fetch('ERX_ERL'), '-noshell', '-pa', work,
                                       '-eval', 'halt(case eunit:test([erx_tty_line_tests, erx_ssh_job_core_tests, erx_ssh_job_tests], [verbose]) of ok -> 0; _ -> 1 end).',
                                       chdir: work, stdin_data: '')
      assert status.success?, output
      assert_match(/All \d+ tests passed/, output)
    end
  end
end
