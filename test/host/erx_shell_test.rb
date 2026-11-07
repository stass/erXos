# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'minitest/autorun'
require 'open3'
require 'tmpdir'

# Runs test/erlang/erx_shell_tests.erl, the EUnit cases of the command shell's
# interactive layer (erx_shell), over the parser, the evaluator and a test runner (erx_shell_basic_runner),
# compiled from source with warnings as errors on stock's emulator (ERX_ERL and ERX_ERLC,
# which make check supplies). A session through the console itself is
# test/integration/runtime_console_test.rb's.
class ErxShellTest < Minitest::Test
  ROOT = File.expand_path('../..', __dir__)
  SOURCES = %w[erlang/apps/erx_shell/src/erx_shell_lex.erl erlang/apps/erx_shell/src/erx_shell_parse.erl
               erlang/apps/erx_shell/src/erx_shell_glob.erl erlang/apps/erx_shell/src/erx_shell_eval.erl
               erlang/apps/erx_shell/src/erx_shell.erl
               test/erlang/erx_shell_basic_runner.erl
               test/erlang/erx_shell_tests.erl].map { |path| File.join(ROOT, path) }.freeze

  def test_interactive_layer_cases_pass_under_eunit
    Dir.mktmpdir('erx-shell-test') do |work|
      output, status = Open3.capture2e(ENV.fetch('ERX_ERLC'), '-Werror', '-o', work, *SOURCES, stdin_data: '')
      assert status.success?, output

      output, status = Open3.capture2e('gtimeout', '-k', '10', '300', ENV.fetch('ERX_ERL'), '-noshell', '-pa', work,
                                       '-eval', 'halt(case eunit:test(erx_shell_tests) of ok -> 0; _ -> 1 end).',
                                       chdir: work, stdin_data: '')
      assert status.success?, output
      assert_match(/All \d+ tests passed/, output)
    end
  end
end
