# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'minitest/autorun'
require 'open3'
require 'tmpdir'
require_relative '../../tools/lib/erx/generated'

# Runs the EUnit cases of `host`, test/erlang/erx_cmd_host_tests.erl, on stock's
# compiler and emulator (ERX_ERLC and ERX_ERL, which make check supplies): its pure
# core, and run/2 against a name server on the loopback interface.
class ErxCmdHostTest < Minitest::Test
  ROOT = File.expand_path('../..', __dir__)
  Erx::Generated.ensure(root: ROOT)
  INCLUDE = Erx::Generated.path('erlang/apps/erx/include', root: ROOT)
  APPLICATION = File.join(ROOT, 'erlang/apps/erx_shell/src')
  # erx_cmd first, so that the command finds its behaviour.
  SOURCES = [File.join(ROOT, 'build/gen/erlang/apps/erx/src/erx_text_tables.erl'),
             File.join(ROOT, 'erlang/apps/erx/src/erx_text.erl'),
             File.join(APPLICATION, 'erx_cmd.erl'),
             File.join(APPLICATION, 'erx_cmd_host.erl'),
             File.join(ROOT, 'test/erlang/erx_cmd_host_tests.erl')].freeze

  def test_host_cases_pass_under_eunit
    Dir.mktmpdir('erx-cmd-host-test') do |work|
      output, status = Open3.capture2e(ENV.fetch('ERX_ERLC'), '-Werror', '-I', INCLUDE, '-pa', work, '-o', work,
                                       *SOURCES, stdin_data: '')
      assert status.success?, output

      output, status = Open3.capture2e('gtimeout', '-k', '10', '120', ENV.fetch('ERX_ERL'), '-noshell', '-pa', work,
                                       '-eval', 'halt(case eunit:test(erx_cmd_host_tests) of ok -> 0; _ -> 1 end).',
                                       chdir: work, stdin_data: '')
      assert status.success?, output
      assert_match(/All \d+ tests passed/, output)
    end
  end
end
