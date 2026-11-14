# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'minitest/autorun'
require 'open3'
require 'tmpdir'
require_relative '../fixtures/erlang_build'
require_relative '../../tools/lib/erx/device_kinds'

# Runs test/erlang/erx_console_shell_tests.erl, the EUnit cases of the console's choice of
# its first shell, of what follows that shell's end and of the group shell:whereis/0
# reports, against erx_console compiled from
# source on stock's emulator (ERX_ERL and ERX_ERLC, which make check supplies); the
# decisions are pure, so they need no hosted build. It also checks the console's drivers
# against erx/device_kinds.h's UART kinds.
class ErxConsoleShellTest < Minitest::Test
  ROOT = File.expand_path('../..', __dir__)
  APPLICATIONS = %w[erx].freeze
  TESTS = %w[test/erlang/erx_console_shell_tests.erl].freeze
  # The hosted entry's console record, -erx_record console stdio (liberx/backend/hosted/start.c),
  # which names no UART and so no row of the table.
  HOSTED = ['console', 'stdio'].freeze

  def test_first_shell_cases_pass_under_eunit
    Dir.mktmpdir('erx-console-shell-test') do |work|
      ErlangBuild.compile(work, applications: APPLICATIONS, tests: TESTS)
      output, status = erl(work, 'halt(case eunit:test(erx_console_shell_tests, [verbose]) of ok -> 0; _ -> 1 end)')
      assert status.success?, output
      assert_match(/All \d+ tests passed/, output)
    end
  end

  # The root writes the console's record from a row of erx/device_kinds.h's erx_uart_kinds, its
  # role word then its PERIPHERAL, and the hosted entry writes console stdio:
  # erx_console:console_driver/1 starts a driver for each. A planted row with no clause is caught.
  def test_every_console_record_the_root_may_write_names_a_driver
    records = Erx::DeviceKinds.uarts(ROOT).map { |kind| [kind.role_word, kind.peripheral] }
    refute_empty records
    Dir.mktmpdir('erx-console-driver-test') do |work|
      ErlangBuild.compile(work, applications: APPLICATIONS, tests: [])
      assert_equal [], driverless(work, [*records, HOSTED])
      assert_equal ['ns16550'], driverless(work, [*records, HOSTED, %w[console ns16550]])
    end
  end

  private

  # The peripherals of the records [word, peripheral] whose console record console_driver/1
  # refuses. The table's reader admits word characters alone in a name, so each is a plain
  # Erlang string literal.
  def driverless(work, records)
    terms = records.map { |word, peripheral| %({"#{word}", "#{peripheral}"}) }.join(', ')
    output, status = erl(work, "[io:format(\"driverless ~s~n\", [P]) || {W, P} <- [#{terms}], " \
                               'element(1, erx_console:console_driver([[W, P]])) =/= ok], ' \
                               "io:format(\"checked ~b~n\", [#{records.size}]), halt(0)")
    assert status.success?, output
    assert_includes output, "checked #{records.size}\n"
    output.scan(/^driverless (\S+)$/).flatten
  end

  def erl(work, expression)
    Open3.capture2e('gtimeout', '-k', '10', '60', ENV.fetch('ERX_ERL'), '-noshell', '-pa', work, '-eval', expression,
                    chdir: work, stdin_data: '')
  end
end
