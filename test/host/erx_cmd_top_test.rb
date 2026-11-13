# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'minitest/autorun'
require 'open3'
require 'tmpdir'
require_relative '../fixtures/erlang_build'

# Runs test/erlang/erx_cmd_top_tests.erl, the EUnit cases of the command
# shell's `top` (docs/design-live.md, "The command shell"), against the
# erx_shell application compiled from source with warnings as errors on
# stock's emulator (ERX_ERL and ERX_ERLC, which make check supplies).
class ErxCmdTopTest < Minitest::Test
  ROOT = File.expand_path('../..', __dir__)
  # The applications the command runs in, compiled whole (ErlangBuild), and the cases. The
  # inspector is a stand-in, compiled after the applications over the real one.
  APPLICATIONS = %w[erx erx_shell].freeze
  TESTS = %w[test/erlang/stand_in/erx_inspector.erl test/erlang/erx_cmd_top_tests.erl].freeze

  def test_top_cases_pass_under_eunit
    Dir.mktmpdir('erx-cmd-top-test') do |work|
      ErlangBuild.compile(work, applications: APPLICATIONS, tests: TESTS)

      output, status = Open3.capture2e('gtimeout', '-k', '10', '300', ENV.fetch('ERX_ERL'), '-noshell', '-pa', work,
                                       '-eval', 'halt(case eunit:test(erx_cmd_top_tests) of ok -> 0; _ -> 1 end).',
                                       chdir: work, stdin_data: '')
      assert status.success?, output
      assert_match(/All \d+ tests passed/, output)
    end
  end
end
