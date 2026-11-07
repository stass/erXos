# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'minitest/autorun'
require 'open3'
require 'tmpdir'
require_relative '../../tools/lib/erx/generated'

# Runs test/erlang/erx_shell_runner_tests.erl, the EUnit cases of the command
# shell's runner, its pipes, its command namespace, the renderer and the
# command context (docs/design-shell.md, "Commands" and "Pipelines"), against
# the erx_shell application compiled from source with warnings as errors on
# stock's emulator (ERX_ERL and ERX_ERLC, which make check supplies). The
# agreement with plan9port's rc is test/integration/erx_shell_commands_test.rb's.
class ErxShellRunnerTest < Minitest::Test
  ROOT = File.expand_path('../..', __dir__)
  # The generated sources and headers named here are in build/gen.
  Erx::Generated.ensure(root: ROOT)
  APPLICATION = File.join(ROOT, 'erlang/apps/erx_shell/src')
  # erx_cmd first, so that the commands find their behaviour.
  SOURCES = [File.join(ROOT, 'build/gen/erlang/apps/erx/src/erx_text_tables.erl'), File.join(ROOT, 'erlang/apps/erx/src/erx_text.erl'),
             File.join(APPLICATION, 'erx_cmd.erl'),
             *Dir[File.join(APPLICATION, '*.erl')].sort,
             File.join(ROOT, 'test/erlang/erx_shell_runner_tests.erl')].uniq.freeze

  def test_runner_cases_pass_under_eunit
    Dir.mktmpdir('erx-shell-runner-test') do |work|
      output, status = Open3.capture2e(ENV.fetch('ERX_ERLC'), '-Werror', '-pa', work, '-o', work, *SOURCES,
                                       stdin_data: '')
      assert status.success?, output

      output, status = Open3.capture2e('gtimeout', '-k', '10', '300', ENV.fetch('ERX_ERL'), '-noshell', '-pa', work,
                                       '-eval', 'halt(case eunit:test(erx_shell_runner_tests) of ok -> 0; _ -> 1 end).',
                                       chdir: work, stdin_data: '')
      assert status.success?, output
      assert_match(/All \d+ tests passed/, output)
    end
  end
end
