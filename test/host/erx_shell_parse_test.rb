# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'minitest/autorun'
require 'open3'
require 'tmpdir'
require_relative '../fixtures/erlang_build'

# Runs test/erlang/erx_shell_parse_tests.erl, the EUnit cases of the command shell's
# tokenizer and parser (docs/design-shell.md, "The language"), against erx_shell_lex
# and erx_shell_parse, which the application compiles with warnings as errors, on stock's emulator
# (ERX_ERL and ERX_ERLC, which make check supplies).
class ErxShellParseTest < Minitest::Test
  ROOT = File.expand_path('../..', __dir__)
  # The application the suite exercises, compiled whole (ErlangBuild), and the suite.
  APPLICATIONS = %w[erx erx_shell].freeze
  TESTS = %w[test/erlang/erx_shell_parse_tests.erl].freeze

  def test_parser_cases_pass_under_eunit
    Dir.mktmpdir('erx-shell-parse-test') do |work|
      ErlangBuild.compile(work, applications: APPLICATIONS, tests: TESTS)

      output, status = Open3.capture2e('gtimeout', '-k', '10', '120', ENV.fetch('ERX_ERL'), '-noshell', '-pa', work,
                                       '-eval', 'halt(case eunit:test(erx_shell_parse_tests) of ok -> 0; _ -> 1 end).',
                                       chdir: work, stdin_data: '')
      assert status.success?, output
      assert_match(/All \d+ tests passed/, output)
    end
  end
end
