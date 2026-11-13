# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'minitest/autorun'
require 'open3'
require 'tmpdir'
require_relative '../fixtures/erlang_build'

# Runs test/erlang/erx_hostlink_tests.erl, the EUnit cases of erx_hostlink's pure parts and
# its install and web facets, compiled from source on stock's emulator (ERX_ERL and
# ERX_ERLC, which make check supplies). erx_device_record and erx_pl011 are not loaded: no
# case starts the host link's process, which the production image's boot runs end to end.
class ErxHostlinkTest < Minitest::Test
  ROOT = File.expand_path('../..', __dir__)
  # The applications, compiled whole (ErlangBuild). The suite's stand-ins, compiled after
  # them, replace erx_dist and erx_bytes, whose BIFs stock's emulator lacks.
  APPLICATIONS = %w[erx erx_hostlink].freeze
  TESTS = %w[test/erlang/stand_in/erx_dist.erl test/erlang/host_bytes/erx_bytes.erl
             test/erlang/erx_hostlink_tests.erl].freeze

  def test_the_host_links_pure_parts_pass_under_eunit
    Dir.mktmpdir('erx-hostlink-test') do |work|
      ErlangBuild.compile(work, applications: APPLICATIONS, tests: TESTS)
      output, status = Open3.capture2e('gtimeout', '-k', '10', '120', ENV.fetch('ERX_ERL'), '-noshell', '-pa', work,
                                       '-eval', 'halt(case eunit:test(erx_hostlink_tests, [verbose]) of ok -> 0; _ -> 1 end)',
                                       chdir: work, stdin_data: '')
      assert status.success?, output
      assert_match(/All \d+ tests passed/, output)
    end
  end
end
