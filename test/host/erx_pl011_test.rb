# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'minitest/autorun'
require 'open3'
require 'tmpdir'
require_relative '../fixtures/erlang_build'

# Runs test/erlang/erx_pl011_tests.erl, the EUnit cases of the console_uart parse, against
# erx_pl011 compiled from source with the rest of its application on stock's emulator
# (ERX_ERL and ERX_ERLC, which make check supplies). The module's calls into erx_device are
# never made by the parse, so it needs no hosted build.
class ErxPl011Test < Minitest::Test
  ROOT = File.expand_path('../..', __dir__)
  # The application, compiled whole (ErlangBuild), and the suite.
  APPLICATIONS = %w[erx_uart].freeze
  TESTS = %w[test/erlang/erx_pl011_tests.erl].freeze

  def test_console_uart_cases_pass_under_eunit
    Dir.mktmpdir('erx-pl011-test') do |work|
      ErlangBuild.compile(work, applications: APPLICATIONS, tests: TESTS)
      output, status = Open3.capture2e('gtimeout', '-k', '10', '60', ENV.fetch('ERX_ERL'), '-noshell', '-pa', work,
                                       '-eval', 'halt(case eunit:test(erx_pl011_tests, [verbose]) of ok -> 0; _ -> 1 end)',
                                       chdir: work, stdin_data: '')
      assert status.success?, output
      assert_match(/All \d+ tests passed/, output)
    end
  end
end
