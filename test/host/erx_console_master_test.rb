# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'minitest/autorun'
require 'open3'
require 'tmpdir'
require_relative '../fixtures/erlang_build'

# Runs the EUnit cases of the console as the master of a session's tty: the pure core
# against arbitrary terms and against the tty's own core (test/erlang/
# erx_tty_master_tests.erl), the Ctrl-G rule and the menu's core (test/erlang/
# erx_console_keys_tests.erl, erx_console_menu_tests.erl), and the console end to end
# behind a console facet
# (test/erlang/erx_console_master_tests.erl), compiled from source with warnings as
# errors on stock's emulator (ERX_ERL and ERX_ERLC, which make check supplies).
class ErxConsoleMasterTest < Minitest::Test
  APPLICATIONS = %w[erx erx_files erx_domain erx_session].freeze
  TESTS = %w[test/erlang/erx_tty_master_tests.erl test/erlang/erx_console_keys_tests.erl
             test/erlang/erx_console_menu_tests.erl test/erlang/erx_console_master_tests.erl].freeze

  def test_master_cases_pass_under_eunit
    Dir.mktmpdir('erx-console-master-test') do |work|
      ErlangBuild.compile(work, applications: APPLICATIONS, tests: TESTS)

      eval = 'halt(case eunit:test([erx_tty_master_tests, erx_console_keys_tests, erx_console_menu_tests, ' \
             'erx_console_master_tests], [verbose]) of ok -> 0; _ -> 1 end).'
      output, status = Open3.capture2e('gtimeout', '-k', '10', '180', ENV.fetch('ERX_ERL'), '-noshell', '-pa', work,
                                       '-eval', eval, chdir: work, stdin_data: '')
      assert status.success?, output
      assert_match(/All \d+ tests passed/, output)
    end
  end
end
