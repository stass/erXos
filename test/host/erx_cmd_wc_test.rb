# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'minitest/autorun'
require 'open3'
require 'tmpdir'
require_relative '../fixtures/erlang_build'

# Runs test/erlang/erx_cmd_wc_tests.erl, the EUnit cases of the command
# shell's `wc` (docs/design-shell.md, "Commands"), among them the golden
# comparison with FreeBSD's wc over test/fixtures/wc, against the erx_shell
# application compiled from source with warnings as errors on stock's emulator
# (ERX_ERL and ERX_ERLC, which make check supplies).
class ErxCmdWcTest < Minitest::Test
  ROOT = File.expand_path('../..', __dir__)
  FIXTURES = File.join(ROOT, 'test/fixtures/wc')
  # The applications the command runs in, compiled whole (ErlangBuild), and the cases.
  APPLICATIONS = %w[erx erx_shell].freeze
  TESTS = %w[test/erlang/erx_cmd_wc_tests.erl].freeze

  def test_wc_cases_pass_under_eunit
    Dir.mktmpdir('erx-cmd-wc-test') do |work|
      ErlangBuild.compile(work, applications: APPLICATIONS, tests: TESTS)

      output, status = Open3.capture2e({ 'ERX_WC_FIXTURES' => FIXTURES },
                                       'gtimeout', '-k', '10', '300', ENV.fetch('ERX_ERL'), '-noshell', '-pa', work,
                                       '-eval', 'halt(case eunit:test(erx_cmd_wc_tests) of ok -> 0; _ -> 1 end).',
                                       chdir: work, stdin_data: '')
      assert status.success?, output
      assert_match(/All \d+ tests passed/, output)
    end
  end
end
