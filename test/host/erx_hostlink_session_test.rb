# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'minitest/autorun'
require 'open3'
require 'tmpdir'
require_relative '../../tools/lib/erx/generated'

# Runs test/erlang/erx_hostlink_session_tests.erl, the EUnit cases of the host link's
# session protocol and its exhaustive exploration, against erx_hostlink_session and the
# frame and stream layers it stands on, compiled from source on stock's emulator (ERX_ERL
# and ERX_ERLC, which make check supplies) with the host stand-in for erx_bytes; they are
# pure, so they need no hosted build.
class ErxHostlinkSessionTest < Minitest::Test
  ROOT = File.expand_path('../..', __dir__)
  # The generated sources and headers named here are in build/gen.
  Erx::Generated.ensure(root: ROOT)
  SOURCES = %w[erlang/apps/erx_hostlink/src/erx_hostlink_frame.erl erlang/apps/erx_hostlink/src/erx_hostlink_stream.erl
               erlang/apps/erx_hostlink/src/erx_hostlink_payload.erl erlang/apps/erx_hostlink/src/erx_hostlink_session.erl
               test/erlang/host_bytes/erx_bytes.erl test/erlang/erx_hostlink_session_tests.erl].freeze

  def test_session_protocol_cases_pass_under_eunit
    Dir.mktmpdir('erx-hostlink-session-test') do |work|
      output, status = Open3.capture2e(ENV.fetch('ERX_ERLC'), '-Werror', '-I', File.join(ROOT, 'build/gen/erlang/apps/erx/include'),
                                       '-o', work, *SOURCES.map { |source| File.join(ROOT, source) }, stdin_data: '')
      assert status.success?, output
      output, status = Open3.capture2e('gtimeout', '-k', '10', '600', ENV.fetch('ERX_ERL'), '-noshell', '-pa', work,
                                       '-eval', 'halt(case eunit:test(erx_hostlink_session_tests, [verbose]) of ok -> 0; _ -> 1 end)',
                                       chdir: work, stdin_data: '')
      assert status.success?, output
      assert_match(/All \d+ tests passed/, output)
    end
  end
end
