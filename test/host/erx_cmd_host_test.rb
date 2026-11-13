# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'minitest/autorun'
require 'open3'
require 'tmpdir'
require_relative '../fixtures/erlang_build'

# Runs the EUnit cases of `host`, test/erlang/erx_cmd_host_tests.erl, on stock's
# compiler and emulator (ERX_ERLC and ERX_ERL, which make check supplies): its pure
# core, and run/2 against a name server on the loopback interface.
class ErxCmdHostTest < Minitest::Test
  ROOT = File.expand_path('../..', __dir__)
  # The applications the command runs in, compiled whole (ErlangBuild), and the cases.
  APPLICATIONS = %w[erx erx_shell].freeze
  TESTS = %w[test/erlang/erx_cmd_host_tests.erl].freeze

  def test_host_cases_pass_under_eunit
    Dir.mktmpdir('erx-cmd-host-test') do |work|
      ErlangBuild.compile(work, applications: APPLICATIONS, tests: TESTS)

      output, status = Open3.capture2e('gtimeout', '-k', '10', '120', ENV.fetch('ERX_ERL'), '-noshell', '-pa', work,
                                       '-eval', 'halt(case eunit:test(erx_cmd_host_tests) of ok -> 0; _ -> 1 end).',
                                       chdir: work, stdin_data: '')
      assert status.success?, output
      assert_match(/All \d+ tests passed/, output)
    end
  end
end
