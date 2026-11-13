# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'minitest/autorun'
require 'open3'
require 'tmpdir'
require_relative '../fixtures/erlang_build'

# Runs test/erlang/erx_text_tests.erl, the EUnit cases of erx_text's line
# escape and field escape,
# against the modules compiled from source with warnings as errors on stock's
# emulator (ERX_ERL and ERX_ERLC, which make check supplies), over the vectors
# test/host/line_escape_test.rb holds the host tool's twin to.
class ErxTextTest < Minitest::Test
  ROOT = File.expand_path('../..', __dir__)
  TESTS = %w[test/erlang/erx_text_tests.erl].freeze
  VECTORS = File.join(ROOT, 'test/fixtures/line_escape_vectors.json')

  def test_text_cases_pass_under_eunit
    Dir.mktmpdir('erx-text-test') do |work|
      ErlangBuild.compile(work, applications: %w[erx], tests: TESTS)

      output, status = Open3.capture2e({ 'ERX_TEXT_VECTORS' => VECTORS },
                                       'gtimeout', '-k', '10', '300', ENV.fetch('ERX_ERL'), '-noshell', '-pa', work,
                                       '-eval', 'halt(case eunit:test(erx_text_tests) of ok -> 0; _ -> 1 end).',
                                       chdir: work, stdin_data: '')
      assert status.success?, output
      assert_match(/All \d+ tests passed/, output)
    end
  end
end
