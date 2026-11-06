# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'minitest/autorun'
require 'open3'
require 'tmpdir'

# Runs test/erlang/erx_shell_parse_tests.erl, the EUnit cases of the command shell's
# tokenizer and parser (docs/design-shell.md, "The language"), against erx_shell_lex
# and erx_shell_parse compiled from source with warnings as errors on stock's emulator
# (ERX_ERL and ERX_ERLC, which make check supplies).
class ErxShellParseTest < Minitest::Test
  ROOT = File.expand_path('../..', __dir__)
  SOURCES = %w[erlang/apps/erx_shell/src/erx_shell_lex.erl erlang/apps/erx_shell/src/erx_shell_parse.erl
               test/erlang/erx_shell_parse_tests.erl].map { |path| File.join(ROOT, path) }.freeze

  def test_parser_cases_pass_under_eunit
    Dir.mktmpdir('erx-shell-parse-test') do |work|
      output, status = Open3.capture2e(ENV.fetch('ERX_ERLC'), '-Werror', '-o', work, *SOURCES, stdin_data: '')
      assert status.success?, output

      output, status = Open3.capture2e('gtimeout', '-k', '10', '120', ENV.fetch('ERX_ERL'), '-noshell', '-pa', work,
                                       '-eval', 'halt(case eunit:test(erx_shell_parse_tests) of ok -> 0; _ -> 1 end).',
                                       chdir: work, stdin_data: '')
      assert status.success?, output
      assert_match(/All \d+ tests passed/, output)
    end
  end
end
