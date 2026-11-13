# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'minitest/autorun'
require 'open3'
require 'tmpdir'
require_relative '../fixtures/erlang_build'

# Runs the EUnit cases of the code service on stock's emulator (ERX_ERL and ERX_ERLC, which
# make check supplies): test/erlang/erx_code_store_tests.erl against its pure core, and
# test/erlang/erx_code_tests.erl against the service loading real modules there. The
# application is compiled whole (ErlangBuild). erx_bytes is the host stand-in,
# test/erlang/host_bytes/erx_bytes.erl, so no hosted build is needed.
class ErxCodeTest < Minitest::Test
  APPLICATIONS = %w[erx_code].freeze
  TESTS = %w[test/erlang/host_bytes/erx_bytes.erl test/erlang/erx_code_store_tests.erl
             test/erlang/erx_code_tests.erl].freeze

  def test_the_store_and_the_service_pass_under_eunit
    Dir.mktmpdir('erx-code-test') do |work|
      ErlangBuild.compile(work, applications: APPLICATIONS, tests: TESTS)
      output, status = Open3.capture2e('gtimeout', '-k', '10', '120', ENV.fetch('ERX_ERL'), '-noshell', '-pa', work,
                                       '-eval', 'halt(case eunit:test([erx_code_store_tests, erx_code_tests], ' \
                                                '[verbose]) of ok -> 0; _ -> 1 end)',
                                       chdir: work, stdin_data: '')
      assert status.success?, output
      assert_match(/All \d+ tests passed/, output)
    end
  end
end
