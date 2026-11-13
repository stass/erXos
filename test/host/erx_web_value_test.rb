# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'minitest/autorun'
require 'open3'
require 'tmpdir'
require_relative '../fixtures/erlang_build'

# Runs test/erlang/erx_web_value_tests.erl, the EUnit cases of the web
# protocol's projection of inspection records (docs/design-web.md, "Values"),
# against erx_web_value and the modules it calls, compiled from source with
# warnings as errors on stock's emulator (ERX_ERL and ERX_ERLC, which make
# check supplies).
class ErxWebValueTest < Minitest::Test
  APPLICATIONS = %w[erx erx_files erx_web_line].freeze
  TESTS = %w[test/erlang/erx_web_value_tests.erl].freeze

  def test_value_cases_pass_under_eunit
    Dir.mktmpdir('erx-web-value-test') do |work|
      ErlangBuild.compile(work, applications: APPLICATIONS, tests: TESTS)
      output, status = Open3.capture2e('gtimeout', '-k', '10', '300', ENV.fetch('ERX_ERL'), '-noshell', '-pa', work,
                                       '-eval', 'halt(case eunit:test(erx_web_value_tests) of ok -> 0; _ -> 1 end).',
                                       chdir: work, stdin_data: '')
      assert status.success?, output
      assert_match(/All \d+ tests passed/, output)
    end
  end
end
