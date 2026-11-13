# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'minitest/autorun'
require 'open3'
require 'tmpdir'
require_relative '../fixtures/erlang_build'

# Runs test/erlang/erx_hostlink_session_tests.erl, the EUnit cases of the host link's
# session protocol and its exhaustive exploration, against erx_hostlink_session and the
# frame and stream layers it stands on, compiled from source on stock's emulator (ERX_ERL
# and ERX_ERLC, which make check supplies) with the host stand-in for erx_bytes; they are
# pure, so they need no hosted build. The exploration stops at depth 5 by default (seconds);
# the milestone gate sets ERX_EXPLORE_DEPTH=full for its whole depth of 8 (minutes).
class ErxHostlinkSessionTest < Minitest::Test
  ROOT = File.expand_path('../..', __dir__)
  # The application, compiled whole (ErlangBuild). The host stand-in for erx_bytes, whose
  # BIFs stock's emulator lacks, is compiled after it and replaces its beam.
  APPLICATIONS = %w[erx erx_hostlink].freeze
  TESTS = %w[test/erlang/host_bytes/erx_bytes.erl test/erlang/erx_hostlink_session_tests.erl].freeze

  def test_session_protocol_cases_pass_under_eunit
    Dir.mktmpdir('erx-hostlink-session-test') do |work|
      ErlangBuild.compile(work, applications: APPLICATIONS, tests: TESTS)
      output, status = Open3.capture2e('gtimeout', '-k', '10', '600', ENV.fetch('ERX_ERL'), '-noshell', '-pa', work,
                                       '-eval', 'halt(case eunit:test(erx_hostlink_session_tests, [verbose]) of ok -> 0; _ -> 1 end)',
                                       chdir: work, stdin_data: '')
      assert status.success?, output
      assert_match(/All \d+ tests passed/, output)
    end
  end
end
