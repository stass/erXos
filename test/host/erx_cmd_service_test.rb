# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'minitest/autorun'
require 'open3'
require 'tmpdir'
require_relative '../fixtures/erlang_build'

# Runs test/erlang/erx_cmd_service_tests.erl, the EUnit cases of the command
# shell's `service` (docs/design-apps.md, "Interfaces"), against the
# erx_shell application compiled from source with warnings as errors on
# stock's emulator (ERX_ERL and ERX_ERLC, which make check supplies).
class ErxCmdServiceTest < Minitest::Test
  ROOT = File.expand_path('../..', __dir__)
  # The applications the command runs in, compiled whole (ErlangBuild), and the cases.
  APPLICATIONS = %w[erx erx_shell].freeze
  TESTS = %w[test/erlang/erx_cmd_service_tests.erl].freeze

  SERVICE = 'erlang/apps/erx_shell/src/erx_cmd_service.erl'
  # The seeded fault: a command on a row that is not enabled acts as on an enabled one.
  ENABLED_CHECK = "act({Name, Command, false, _Settings}, false, _State, _Row) ->"
  NO_CHECK = "act({Name, Command, false, _Settings}, false, _State, _Row) when Name =:= <<>> ->"

  def test_service_cases_pass_under_eunit
    output = eunit({})
    assert_match(/All \d+ tests passed/, output)
  end

  def test_the_cases_catch_a_command_that_skips_the_enabled_check
    text = File.read(File.join(ROOT, SERVICE))
    assert_equal 1, text.scan(ENABLED_CHECK).size
    output = eunit({ SERVICE => text.sub(ENABLED_CHECK) { NO_CHECK } }, passes: false)
    assert_match(/start_of_a_row_not_enabled_names_onestart_test[^\n]*\*failed\*/, output)
  end

  private

  def eunit(replaced, passes: true)
    Dir.mktmpdir('erx-cmd-service-test') do |work|
      ErlangBuild.compile(work, applications: APPLICATIONS, tests: TESTS, replaced: replaced)

      output, status = Open3.capture2e('gtimeout', '-k', '10', '120', ENV.fetch('ERX_ERL'), '-noshell', '-pa', work,
                                       '-eval', 'halt(case eunit:test(erx_cmd_service_tests, [verbose]) of ok -> 0; _ -> 1 end).',
                                       chdir: work, stdin_data: '')
      assert_equal passes, status.success?, output
      output
    end
  end
end
