# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'minitest/autorun'
require 'open3'
require 'tmpdir'
require_relative '../../tools/lib/erx/generated'

# Runs test/erlang/erx_shell_text_tests.erl, the EUnit cases of the command
# shell's text commands, `sort`, `grep`, `ps` and `ls`, and their pipelines
# (docs/design-shell.md, "Text commands"), against the erx_shell
# application compiled from source with warnings as errors on stock's emulator
# (ERX_ERL and ERX_ERLC, which make check supplies).
class ErxShellTextTest < Minitest::Test
  ROOT = File.expand_path('../..', __dir__)
  # The generated sources and headers named here are in build/gen.
  Erx::Generated.ensure(root: ROOT)
  # The generated headers erx_shell includes, such as erx_abi.hrl.
  INCLUDE = Erx::Generated.path('erlang/apps/erx/include', root: ROOT)
  APPLICATION = File.join(ROOT, 'erlang/apps/erx_shell/src')
  # erx_cmd first, so that the commands find their behaviour.
  SOURCES = [File.join(ROOT, 'build/gen/erlang/apps/erx/src/erx_text_tables.erl'), File.join(ROOT, 'erlang/apps/erx/src/erx_text.erl'),
             File.join(ROOT, 'erlang/apps/erx/src/erx_facets.erl'),
             File.join(APPLICATION, 'erx_cmd.erl'),
             *Dir[File.join(APPLICATION, '*.erl')].sort,
             File.join(ROOT, 'test/erlang/erx_shell_text_tests.erl')].uniq.freeze

  def test_text_cases_pass_under_eunit
    Dir.mktmpdir('erx-shell-text-test') do |work|
      output, status = Open3.capture2e(ENV.fetch('ERX_ERLC'), '-Werror', '-I', INCLUDE, '-pa', work, '-o', work, *SOURCES,
                                       stdin_data: '')
      assert status.success?, output

      output, status = Open3.capture2e('gtimeout', '-k', '10', '300', ENV.fetch('ERX_ERL'), '-noshell', '-pa', work,
                                       '-eval', 'halt(case eunit:test(erx_shell_text_tests) of ok -> 0; _ -> 1 end).',
                                       chdir: work, stdin_data: '')
      assert status.success?, output
      assert_match(/All \d+ tests passed/, output)
    end
  end
end
