# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'fileutils'
require 'minitest/autorun'
require 'open3'
require 'tmpdir'
require_relative '../../tools/lib/erx/generated'

# Runs test/erlang/erx_session_tty_tests.erl, the EUnit cases of the session's tty relay
# (erx_session_tty) with the command shell on it and a fake master, against the relay,
# erx_console and the erx_shell application compiled from source with warnings as errors
# on stock's emulator (ERX_ERL and ERX_ERLC, which make check supplies). The shell finds
# its commands through erx_shell's application file, copied beside the beams.
class ErxSessionTtyTest < Minitest::Test
  ROOT = File.expand_path('../..', __dir__)
  Erx::Generated.ensure(root: ROOT)
  INCLUDE = Erx::Generated.path('erlang/apps/erx/include', root: ROOT)
  SHELL = File.join(ROOT, 'erlang/apps/erx_shell/src')
  # erx_cmd first, so that the commands find their behaviour.
  SOURCES = [Erx::Generated.path('erlang/apps/erx/src/erx_text_tables.erl', root: ROOT),
             *%w[erlang/apps/erx/src/erx_text.erl erlang/apps/erx/src/erx.erl erlang/apps/erx/src/erx_facets.erl
                 erlang/apps/erx/src/erx_console.erl
                 erlang/apps/erx/src/erx_console_log.erl erlang/apps/erx/src/erx_console_keys.erl
                 erlang/apps/erx/src/erx_console_menu.erl
                 erlang/apps/erx_session/src/erx_tty_link.erl
                 erlang/apps/erx_session/src/erx_session_tty.erl].map { |path| File.join(ROOT, path) },
             File.join(SHELL, 'erx_cmd.erl'), *Dir[File.join(SHELL, '*.erl')].sort,
             File.join(ROOT, 'test/erlang/erx_session_tty_tests.erl')].uniq.freeze

  def test_relay_cases_pass_under_eunit
    Dir.mktmpdir('erx-session-tty-test') do |work|
      output, status = Open3.capture2e(ENV.fetch('ERX_ERLC'), '-Werror', '-I', INCLUDE, '-pa', work, '-o', work, *SOURCES,
                                       stdin_data: '')
      assert status.success?, output
      FileUtils.cp(File.join(SHELL, 'erx_shell.app.src'), File.join(work, 'erx_shell.app'))

      output, status = Open3.capture2e('gtimeout', '-k', '10', '120', ENV.fetch('ERX_ERL'), '-noshell', '-pa', work,
                                       '-eval', 'halt(case eunit:test(erx_session_tty_tests, [verbose]) of ok -> 0; _ -> 1 end).',
                                       chdir: work, stdin_data: '')
      assert status.success?, output
      assert_match(/Test passed\.|All \d+ tests passed/, output)
    end
  end
end
