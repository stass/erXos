# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'minitest/autorun'
require 'open3'
require 'tmpdir'
require_relative '../../tools/lib/erx/generated'

# Runs the EUnit cases of the console as the master of a session's tty: the pure core
# against arbitrary terms and against the tty's own core (test/erlang/
# erx_tty_master_tests.erl), and the console end to end behind a console facet
# (test/erlang/erx_console_master_tests.erl), compiled from source with warnings as
# errors on stock's emulator (ERX_ERL and ERX_ERLC, which make check supplies).
class ErxConsoleMasterTest < Minitest::Test
  ROOT = File.expand_path('../..', __dir__)
  Erx::Generated.ensure(root: ROOT)
  INCLUDE = Erx::Generated.path('erlang/apps/erx/include', root: ROOT)
  SOURCES = [Erx::Generated.path('erlang/apps/erx/src/erx_text_tables.erl', root: ROOT),
             *%w[erlang/apps/erx/src/erx_text.erl erlang/apps/erx/src/erx_console.erl
                 erlang/apps/erx/src/erx_console_log.erl erlang/apps/erx/src/erx_tty_master.erl
                 erlang/apps/erx/src/erx_facet.erl erlang/apps/erx_domain/src/erx_domain_facet.erl
                 erlang/apps/erx_session/src/erx_tty_link.erl
                 test/erlang/erx_tty_master_tests.erl
                 test/erlang/erx_console_master_tests.erl].map { |path| File.join(ROOT, path) }].freeze

  def test_master_cases_pass_under_eunit
    Dir.mktmpdir('erx-console-master-test') do |work|
      output, status = Open3.capture2e(ENV.fetch('ERX_ERLC'), '-Werror', '-I', INCLUDE, '-o', work, *SOURCES,
                                       stdin_data: '')
      assert status.success?, output

      eval = 'halt(case eunit:test([erx_tty_master_tests, erx_console_master_tests], [verbose]) ' \
             'of ok -> 0; _ -> 1 end).'
      output, status = Open3.capture2e('gtimeout', '-k', '10', '180', ENV.fetch('ERX_ERL'), '-noshell', '-pa', work,
                                       '-eval', eval, chdir: work, stdin_data: '')
      assert status.success?, output
      assert_match(/All \d+ tests passed/, output)
    end
  end
end
