# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'minitest/autorun'
require 'open3'
require 'tmpdir'

# Runs test/erlang/erx_ns_tests.erl, the EUnit cases of the namespace table's one
# writer, against erx_ns compiled from source with warnings as errors on stock's
# emulator (ERX_ERL and ERX_ERLC, which make check supplies), over the stub of
# prim_file the cases start it with.
class ErxNsTest < Minitest::Test
  ROOT = File.expand_path('../..', __dir__)
  SOURCES = %w[erlang/apps/erx/src/erx_ns.erl test/erlang/erx_ns_prim_stub.erl
               test/erlang/erx_ns_tests.erl].map { |path| File.join(ROOT, path) }.freeze
  INCLUDE = File.join(ROOT, 'erlang/apps/erx/include')

  def test_writer_cases_pass_under_eunit
    output, status = eunit
    assert status.success?, output
    assert_match(/All \d+ tests passed/, output)
  end

  private

  def eunit
    Dir.mktmpdir('erx-ns-test') do |work|
      output, status = Open3.capture2e(ENV.fetch('ERX_ERLC'), '-Werror', '-I', INCLUDE, '-o', work, *SOURCES,
                                       stdin_data: '')
      return [output, status] unless status.success?

      Open3.capture2e('gtimeout', '-k', '10', '120', ENV.fetch('ERX_ERL'), '-noshell', '-pa', work,
                      '-eval', 'halt(case eunit:test(erx_ns_tests, [verbose]) of ok -> 0; _ -> 1 end)',
                      chdir: work, stdin_data: '')
    end
  end
end
