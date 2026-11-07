# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'minitest/autorun'
require 'open3'
require 'tmpdir'

# Runs the EUnit cases of the code service on stock's emulator (ERX_ERL and ERX_ERLC, which
# make check supplies): test/erlang/erx_code_store_tests.erl against its pure core, and
# test/erlang/erx_code_tests.erl against the service loading real modules there. erx_bytes is
# the host stand-in, test/erlang/host_bytes/erx_bytes.erl, so no hosted build is needed.
class ErxCodeTest < Minitest::Test
  ROOT = File.expand_path('../..', __dir__)
  SOURCES = %w[erlang/apps/erx_code/src/erx_code_store.erl erlang/apps/erx_code/src/erx_code.erl
               test/erlang/host_bytes/erx_bytes.erl test/erlang/erx_code_store_tests.erl
               test/erlang/erx_code_tests.erl].freeze

  def test_the_store_and_the_service_pass_under_eunit
    Dir.mktmpdir('erx-code-test') do |work|
      output, status = Open3.capture2e(ENV.fetch('ERX_ERLC'), '-Werror', '-o', work,
                                       *SOURCES.map { |source| File.join(ROOT, source) }, stdin_data: '')
      assert status.success?, output
      output, status = Open3.capture2e('gtimeout', '-k', '10', '120', ENV.fetch('ERX_ERL'), '-noshell', '-pa', work,
                                       '-eval', 'halt(case eunit:test([erx_code_store_tests, erx_code_tests], ' \
                                                '[verbose]) of ok -> 0; _ -> 1 end)',
                                       chdir: work, stdin_data: '')
      assert status.success?, output
      assert_match(/All \d+ tests passed/, output)
    end
  end
end
