# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'minitest/autorun'
require 'open3'
require 'tmpdir'
require_relative '../fixtures/erlang_build'

# Runs test/erlang/erx_ui_lvgl_core_tests.erl, the exhaustive EUnit cases of the LVGL
# renderer's decisions about its program's pipes (docs/design-display.md, "The widget
# server"), against erx_ui_lvgl_core compiled from source with warnings as errors on
# stock's emulator (ERX_ERL and ERX_ERLC, which make check supplies).
class ErxUiLvglCoreTest < Minitest::Test
  ROOT = File.expand_path('../..', __dir__)
  TESTS = %w[test/erlang/erx_ui_lvgl_core_tests.erl].freeze
  DEADLINE = '300'

  def test_protocol_cases_pass_under_eunit
    Dir.mktmpdir('erx-ui-lvgl-core-test') do |work|
      ErlangBuild.compile(work, applications: %w[erx erx_ui], tests: TESTS)

      output, status = run_bounded(ENV.fetch('ERX_ERL'), '-noshell', '-pa', work, '-eval',
                                   'halt(case eunit:test(erx_ui_lvgl_core_tests, [verbose]) of ok -> 0; _ -> 1 end).')
      assert status.success?, output
      assert_match(/All \d+ tests passed/, output)
    end
  end

  private

  def run_bounded(*command) = Open3.capture2e('gtimeout', '-k', '10', DEADLINE, *command, stdin_data: '')
end
