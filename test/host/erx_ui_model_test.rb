# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'minitest/autorun'
require 'open3'
require 'tmpdir'
require_relative '../fixtures/erlang_build'

# Runs test/erlang/erx_ui_model_tests.erl, the EUnit cases of the realised widget tree's
# difference (docs/design-display.md, "Widget trees"), against erx_ui_model compiled from
# source with warnings as errors on stock's emulator (ERX_ERL and ERX_ERLC, which make
# check supplies).
class ErxUiModelTest < Minitest::Test
  ROOT = File.expand_path('../..', __dir__)
  TESTS = %w[test/erlang/erx_ui_model_tests.erl].freeze
  DEADLINE = '300'

  def test_difference_cases_pass_under_eunit
    Dir.mktmpdir('erx-ui-model-test') do |work|
      ErlangBuild.compile(work, applications: %w[erx erx_display], tests: TESTS)

      output, status = run_bounded(ENV.fetch('ERX_ERL'), '-noshell', '-pa', work, '-eval',
                                   'halt(case eunit:test(erx_ui_model_tests, [verbose]) of ok -> 0; _ -> 1 end).')
      assert status.success?, output
      assert_match(/All \d+ tests passed/, output)
    end
  end

  private

  def run_bounded(*command) = Open3.capture2e('gtimeout', '-k', '10', DEADLINE, *command, stdin_data: '')
end
