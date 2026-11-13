# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'minitest/autorun'
require 'open3'
require 'tmpdir'
require_relative '../fixtures/erlang_build'

# Runs test/erlang/erx_web_relay_tests.erl, the EUnit cases of the web domain's relay of
# the host link's web facet (docs/design-web.md, "The host tool's front end"), against
# erx_web_relay, erx_web_relay_conn, erx_web_conn and the generated erx_web_proto,
# compiled from source with warnings as errors on stock's emulator (ERX_ERL and ERX_ERLC,
# which make check supplies). erx_facet is compiled for provide/2 and erx_driver_ctl for
# the mint's check; no case starts a facet, whose export needs erXos's erx_dist.
class ErxWebRelayTest < Minitest::Test
  APPLICATIONS = %w[erx erx_web].freeze
  TESTS = %w[test/erlang/erx_web_relay_tests.erl].freeze

  def test_relay_cases_pass_under_eunit
    Dir.mktmpdir('erx-web-relay-test') do |work|
      ErlangBuild.compile(work, applications: APPLICATIONS, tests: TESTS)
      output, status = Open3.capture2e('gtimeout', '-k', '10', '300', ENV.fetch('ERX_ERL'), '-noshell', '-pa', work,
                                       '-eval', 'halt(case eunit:test(erx_web_relay_tests, [verbose]) of ok -> 0; _ -> 1 end).',
                                       chdir: work, stdin_data: '')
      assert status.success?, output
      assert_match(/All \d+ tests passed/, output)
    end
  end
end
