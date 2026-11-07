# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'minitest/autorun'
require 'open3'
require 'tmpdir'
require_relative '../../tools/lib/erx/generated'

# Runs test/erlang/erx_path_tests.erl, the EUnit cases of the path resolver, against
# erx_path compiled from source with warnings as errors on stock's emulator (ERX_ERL and
# ERX_ERLC, which make check supplies), with the model tree and executor the cases drive
# it through. The fuzz target, tools/fuzz/erx_path.rb, seeds the design's faults.
class ErxPathTest < Minitest::Test
  ROOT = File.expand_path('../..', __dir__)
  # The generated sources and headers named here are in build/gen.
  Erx::Generated.ensure(root: ROOT)
  SOURCES = %w[otp/erts/preloaded/src/erx_path.erl test/erlang/erx_path_tree.erl
               test/erlang/erx_path_tests.erl].map { |path| File.join(ROOT, path) }.freeze
  INCLUDE = File.join(ROOT, 'build/gen/erlang/apps/erx/include')

  def test_resolver_cases_pass_under_eunit
    output, status = eunit
    assert status.success?, output
    assert_match(/All \d+ tests passed/, output)
  end

  private

  def eunit
    Dir.mktmpdir('erx-path-test') do |work|
      output, status = Open3.capture2e(ENV.fetch('ERX_ERLC'), '-Werror', '-I', INCLUDE, '-o', work, *SOURCES,
                                       stdin_data: '')
      return [output, status] unless status.success?

      Open3.capture2e('gtimeout', '-k', '10', '120', ENV.fetch('ERX_ERL'), '-noshell', '-pa', work,
                      '-eval', 'halt(case eunit:test(erx_path_tests, [verbose]) of ok -> 0; _ -> 1 end)',
                      chdir: work, stdin_data: '')
    end
  end
end
