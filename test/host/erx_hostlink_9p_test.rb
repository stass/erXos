# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'minitest/autorun'
require 'open3'
require 'tmpdir'
require_relative '../fixtures/erlang_build'

# Runs test/erlang/erx_hostlink_9p_tests.erl, the EUnit cases of the host link's 9P bridge
# (erx_hostlink_9p's core and erx_hostlink_files over a real erx_fs grant of
# erx_fs_test_tree, and erx_build's reading of the manifest's development flag),
# compiled from source on stock's emulator (ERX_ERL and ERX_ERLC, which make check
# supplies) with the generated grammar from build/gen.
class ErxHostlink9pTest < Minitest::Test
  ROOT = File.expand_path('../..', __dir__)
  # The applications the suite exercises, compiled whole (ErlangBuild), the generated
  # grammar (in build/gen, outside the applications) and the suite. The test tree declares
  # the erx_fs behaviour, which erx_files supplies.
  APPLICATIONS = %w[erx erx_files erx_hostlink].freeze
  TESTS = %w[build/gen/otp/erts/preloaded/src/erx_9p_grammar.erl
             test/erlang/erx_fs_test_tree.erl test/erlang/erx_hostlink_9p_tests.erl].freeze

  def test_the_bridge_passes_under_eunit
    Dir.mktmpdir('erx-hostlink-9p-test') do |work|
      ErlangBuild.compile(work, applications: APPLICATIONS, tests: TESTS)
      output, status = Open3.capture2e('gtimeout', '-k', '10', '120', ENV.fetch('ERX_ERL'), '-noshell', '-pa', work,
                                       '-eval', 'halt(case eunit:test(erx_hostlink_9p_tests, [verbose]) of ok -> 0; _ -> 1 end)',
                                       chdir: work, stdin_data: '')
      assert status.success?, output
      assert_match(/All \d+ tests passed/, output)
    end
  end
end
