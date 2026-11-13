# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'minitest/autorun'
require 'open3'
require 'tmpdir'
require_relative '../fixtures/erlang_build'

# Runs test/erlang/erx_web_line_tests.erl, the EUnit cases of the session's line to the web
# domain (docs/design-web.md, "Views on the line"), and of the path from a browser's open
# through the relay's connection and the line to an update carrying the machine's record,
# compiled from source with warnings as errors on stock's emulator (ERX_ERL and ERX_ERLC,
# which make check supplies). The export table is the test's stand-in, and so is the
# inspector but in the cases of a domain's processes and of the scope, which ask it itself.
class ErxWebLineTest < Minitest::Test
  APPLICATIONS = %w[erx erx_files erx_web erx_web_line].freeze
  TESTS = %w[test/erlang/erx_web_line_tests.erl].freeze

  def test_relay_cases_pass_under_eunit
    Dir.mktmpdir('erx-web-line-test') do |work|
      ErlangBuild.compile(work, applications: APPLICATIONS, tests: TESTS)
      output, status = Open3.capture2e('gtimeout', '-k', '10', '300', ENV.fetch('ERX_ERL'), '-noshell', '-pa', work,
                                       '-eval', 'halt(case eunit:test(erx_web_line_tests, [verbose]) of ok -> 0; _ -> 1 end).',
                                       chdir: work, stdin_data: '')
      assert status.success?, output
      assert_match(/All \d+ tests passed/, output)
    end
  end
end
