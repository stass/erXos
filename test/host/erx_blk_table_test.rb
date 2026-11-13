# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'minitest/autorun'
require 'open3'
require 'tmpdir'
require_relative '../fixtures/erlang_build'

# Runs test/erlang/erx_blk_table_tests.erl, the EUnit cases of the boot medium's partition
# table and a window's check, against erx_blk_table compiled from source on stock's emulator
# (ERX_ERL and ERX_ERLC, which make check supplies); it is pure, so it needs no hosted build.
class ErxBlkTableTest < Minitest::Test
  ROOT = File.expand_path('../..', __dir__)
  # The application the cases exercise, compiled whole (ErlangBuild), and the cases.
  APPLICATIONS = %w[erx erx_blk].freeze
  TESTS = %w[test/erlang/erx_blk_table_tests.erl].freeze

  def test_partition_table_cases_pass_under_eunit
    Dir.mktmpdir('erx-blk-table-test') do |work|
      ErlangBuild.compile(work, applications: APPLICATIONS, tests: TESTS)
      output, status = Open3.capture2e('gtimeout', '-k', '10', '60', ENV.fetch('ERX_ERL'), '-noshell', '-pa', work,
                                       '-eval', 'halt(case eunit:test(erx_blk_table_tests, [verbose]) of ok -> 0; _ -> 1 end)',
                                       chdir: work, stdin_data: '')
      assert status.success?, output
      assert_match(/All \d+ tests passed/, output)
    end
  end
end
