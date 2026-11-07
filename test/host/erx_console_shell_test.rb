# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'minitest/autorun'
require 'open3'
require 'tmpdir'

# Runs test/erlang/erx_console_shell_tests.erl, the EUnit cases of the console's choice of
# its first shell and of what follows that shell's end, against erx_console compiled from
# source on stock's emulator (ERX_ERL and ERX_ERLC, which make check supplies); the
# decisions are pure, so they need no hosted build.
class ErxConsoleShellTest < Minitest::Test
  ROOT = File.expand_path('../..', __dir__)
  SOURCES = %w[erlang/apps/erx/src/erx_console.erl test/erlang/erx_console_shell_tests.erl].freeze

  def test_first_shell_cases_pass_under_eunit
    Dir.mktmpdir('erx-console-shell-test') do |work|
      output, status = Open3.capture2e(ENV.fetch('ERX_ERLC'), '-Werror', '-o', work,
                                       *SOURCES.map { |source| File.join(ROOT, source) }, stdin_data: '')
      assert status.success?, output
      output, status = Open3.capture2e('gtimeout', '-k', '10', '60', ENV.fetch('ERX_ERL'), '-noshell', '-pa', work,
                                       '-eval', 'halt(case eunit:test(erx_console_shell_tests, [verbose]) of ok -> 0; _ -> 1 end)',
                                       chdir: work, stdin_data: '')
      assert status.success?, output
      assert_match(/All \d+ tests passed/, output)
    end
  end
end
