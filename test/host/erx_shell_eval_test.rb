# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'minitest/autorun'
require 'open3'
require 'tmpdir'
require_relative '../fixtures/erlang_build'

# Runs test/erlang/erx_shell_eval_tests.erl, the EUnit cases of the command shell's
# evaluator (docs/design-shell.md, "The language"), against erx_shell_eval, the parser
# it walks and erx_shell_fake_runner, compiled from source with warnings as errors on
# stock's emulator (ERX_ERL and ERX_ERLC, which make check supplies). The agreement
# with plan9port's rc is test/integration/erx_shell_corpus_test.rb's.
class ErxShellEvalTest < Minitest::Test
  ROOT = File.expand_path('../..', __dir__)
  # The application the suite exercises, compiled whole (ErlangBuild), and the suite with
  # its fake runner.
  APPLICATIONS = %w[erx erx_shell].freeze
  TESTS = %w[test/erlang/erx_shell_fake_runner.erl test/erlang/erx_shell_eval_tests.erl].freeze

  def test_evaluator_cases_pass_under_eunit
    Dir.mktmpdir('erx-shell-eval-test') do |work|
      ErlangBuild.compile(work, applications: APPLICATIONS, tests: TESTS)

      output, status = Open3.capture2e('gtimeout', '-k', '10', '300', ENV.fetch('ERX_ERL'), '-noshell', '-pa', work,
                                       '-eval', 'halt(case eunit:test(erx_shell_eval_tests) of ok -> 0; _ -> 1 end).',
                                       chdir: work, stdin_data: '')
      assert status.success?, output
      assert_match(/All \d+ tests passed/, output)
    end
  end
end
