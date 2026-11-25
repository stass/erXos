# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'minitest/autorun'
require 'open3'
require 'tmpdir'
require_relative '../fixtures/erlang_build'

# Runs test/erlang/erx_bleuart_core_tests.erl, the EUnit cases of bleuart's relay
# (docs/design-bluetooth.md, "The console", the relay row of its tests): a phone's
# bytes become root's tty's input in order and a serial_lost one NUL between them,
# output is held until the client subscribes, a disconnect hangs the tty up, and no
# other domain's message reaches the master. The erx and erx_bleuart applications are
# compiled from source with warnings as errors on stock's emulator (ERX_ERL and
# ERX_ERLC, which make check supplies).
class ErxBleuartTest < Minitest::Test
  APPLICATIONS = %w[erx erx_bt_client erx_bleuart].freeze
  TESTS = %w[test/erlang/erx_bleuart_core_tests.erl].freeze

  def test_relay_cases_pass_under_eunit
    Dir.mktmpdir('erx-bleuart-test') do |work|
      ErlangBuild.compile(work, applications: APPLICATIONS, tests: TESTS)

      output, status = Open3.capture2e('gtimeout', '-k', '10', '120', ENV.fetch('ERX_ERL'), '-noshell', '-pa', work,
                                       '-eval', 'halt(case eunit:test(erx_bleuart_core_tests) of ok -> 0; _ -> 1 end).',
                                       chdir: work, stdin_data: '')
      assert status.success?, output
      assert_match(/All \d+ tests passed/, output)
    end
  end
end
