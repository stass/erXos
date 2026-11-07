# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'minitest/autorun'
require 'open3'
require 'tmpdir'

# Runs test/erlang/erx_shell_eval_tests.erl, the EUnit cases of the command shell's
# evaluator (docs/design-shell.md, "The language"), against erx_shell_eval, the parser
# it walks and erx_shell_fake_runner, compiled from source with warnings as errors on
# stock's emulator (ERX_ERL and ERX_ERLC, which make check supplies). The agreement
# with plan9port's rc is test/integration/erx_shell_corpus_test.rb's.
class ErxShellEvalTest < Minitest::Test
  ROOT = File.expand_path('../..', __dir__)
  SOURCES = %w[erlang/apps/erx_shell/src/erx_shell_lex.erl erlang/apps/erx_shell/src/erx_shell_parse.erl
               erlang/apps/erx_shell/src/erx_shell_glob.erl erlang/apps/erx_shell/src/erx_shell_eval.erl
               test/erlang/erx_shell_fake_runner.erl
               test/erlang/erx_shell_eval_tests.erl].map { |path| File.join(ROOT, path) }.freeze

  def test_evaluator_cases_pass_under_eunit
    Dir.mktmpdir('erx-shell-eval-test') do |work|
      output, status = Open3.capture2e(ENV.fetch('ERX_ERLC'), '-Werror', '-o', work, *SOURCES, stdin_data: '')
      assert status.success?, output

      output, status = Open3.capture2e('gtimeout', '-k', '10', '300', ENV.fetch('ERX_ERL'), '-noshell', '-pa', work,
                                       '-eval', 'halt(case eunit:test(erx_shell_eval_tests) of ok -> 0; _ -> 1 end).',
                                       chdir: work, stdin_data: '')
      assert status.success?, output
      assert_match(/All \d+ tests passed/, output)
    end
  end
end
