# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'minitest/autorun'
require 'open3'
require 'tmpdir'
require_relative '../fixtures/erlang_build'

# Runs test/erlang/erx_cmd_reboot_tests.erl, the EUnit cases of the command
# shell's `reboot` and `halt` (erx_cmd_reboot): the parser, the usage lines and
# the authority rule, against the erx and erx_shell applications compiled from
# source with warnings as errors on stock's emulator (ERX_ERL and ERX_ERLC,
# which make check supplies). No case ends the emulator.
class ErxCmdRebootTest < Minitest::Test
  APPLICATIONS = %w[erx erx_shell].freeze
  TESTS = %w[test/erlang/erx_cmd_reboot_tests.erl].freeze

  def test_reboot_cases_pass_under_eunit
    Dir.mktmpdir('erx-cmd-reboot-test') do |work|
      ErlangBuild.compile(work, applications: APPLICATIONS, tests: TESTS)

      output, status = Open3.capture2e('gtimeout', '-k', '10', '120', ENV.fetch('ERX_ERL'), '-noshell', '-pa', work,
                                       '-eval', 'halt(case eunit:test(erx_cmd_reboot_tests) of ok -> 0; _ -> 1 end).',
                                       chdir: work, stdin_data: '')
      assert status.success?, output
      assert_match(/All \d+ tests passed/, output)
    end
  end
end
