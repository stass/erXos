# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'minitest/autorun'
require 'open3'
require 'tmpdir'
require_relative '../fixtures/erlang_build'

# Runs test/erlang/erx_cmd_load_tests.erl, the EUnit cases of the session's
# `load` (docs/design-live.md, "One load, three routes"), against the erx_shell and
# erx_code applications compiled from source with warnings as errors on
# stock's emulator (ERX_ERL and ERX_ERLC, which make check supplies).
class ErxCmdLoadTest < Minitest::Test
  # The applications the command runs in, compiled whole (ErlangBuild), and the cases.
  APPLICATIONS = %w[erx erx_shell erx_code].freeze
  TESTS = %w[test/erlang/host_bytes/erx_bytes.erl test/erlang/erx_test_dir.erl test/erlang/erx_cmd_load_tests.erl].freeze

  def test_load_cases_pass_under_eunit
    Dir.mktmpdir('erx-cmd-load-test') do |work|
      ErlangBuild.compile(work, applications: APPLICATIONS, tests: TESTS)

      output, status = Open3.capture2e('gtimeout', '-k', '10', '120', ENV.fetch('ERX_ERL'), '-noshell', '-pa', work,
                                       '-eval', 'halt(case eunit:test(erx_cmd_load_tests) of ok -> 0; _ -> 1 end).',
                                       chdir: work, stdin_data: '')
      assert status.success?, output
      assert_match(/All \d+ tests passed/, output)
    end
  end
end
