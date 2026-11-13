# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'minitest/autorun'
require 'open3'
require 'tmpdir'
require_relative '../fixtures/erlang_build'

# Runs test/erlang/erx_ui_server_tests.erl, the EUnit cases of the widget toolkit's
# client library and widget server (docs/design-display.md, "The widget server"), over a
# renderer the test module plays, against erx_win compiled from source with warnings as
# errors on stock's emulator (ERX_ERL and ERX_ERLC, which make check supplies).
class ErxUiServerTest < Minitest::Test
  ROOT = File.expand_path('../..', __dir__)
  TESTS = %w[test/erlang/erx_ui_server_tests.erl].freeze
  DEADLINE = '300'

  def test_widget_server_cases_pass_under_eunit
    Dir.mktmpdir('erx-ui-server-test') do |work|
      ErlangBuild.compile(work, applications: %w[erx erx_win], tests: TESTS)

      output, status = Open3.capture2e('gtimeout', '-k', '10', DEADLINE, ENV.fetch('ERX_ERL'), '-noshell', '-pa', work,
                                       '-eval', 'halt(case eunit:test(erx_ui_server_tests, [verbose]) of ok -> 0; _ -> 1 end).',
                                       stdin_data: '')
      assert status.success?, output
      assert_match(/All \d+ tests passed/, output)
    end
  end
end
