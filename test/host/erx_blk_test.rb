# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'minitest/autorun'
require 'open3'
require 'tmpdir'
require_relative '../fixtures/erlang_build'

# Runs test/erlang/erx_blk_tests.erl, the EUnit cases of the block driver's choice of
# transport by the block record's peripheral, and test/erlang/erx_blk_window_tests.erl,
# those of a window's tie to the device process it reached first, against erx_blk,
# erx_blk_window and erx_device_record compiled from source on stock's emulator (ERX_ERL
# and ERX_ERLC, which make check supplies). The cases reach the pure erx_blk:choose/1 and
# a window over a stand-in device process, so they need no hosted build.
class ErxBlkTest < Minitest::Test
  # The applications the cases exercise, compiled whole (ErlangBuild), and the cases.
  APPLICATIONS = %w[erx erx_blk].freeze
  TESTS = %w[test/erlang/erx_blk_tests.erl test/erlang/erx_blk_window_tests.erl].freeze

  def test_transport_choice_and_window_cases_pass_under_eunit
    Dir.mktmpdir('erx-blk-test') do |work|
      ErlangBuild.compile(work, applications: APPLICATIONS, tests: TESTS)
      output, status = Open3.capture2e('gtimeout', '-k', '10', '60', ENV.fetch('ERX_ERL'), '-noshell', '-pa', work,
                                       '-eval', 'halt(case eunit:test([erx_blk_tests, erx_blk_window_tests], [verbose]) of ok -> 0; _ -> 1 end)',
                                       chdir: work, stdin_data: '')
      assert status.success?, output
      assert_match(/All \d+ tests passed/, output)
    end
  end
end
