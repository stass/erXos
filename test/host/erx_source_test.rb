# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'minitest/autorun'
require 'open3'
require 'tmpdir'
require_relative '../../tools/lib/erx/generated'

# Runs test/erlang/erx_source_tests.erl, the EUnit cases of erx_source, the
# lines of source a process is at, and of erx:source/1, against the modules
# compiled from source with warnings as errors on stock's emulator (ERX_ERL
# and ERX_ERLC, which make check supplies). The cases compile a probe module
# into a directory under the working directory, a fresh one for each run.
class ErxSourceTest < Minitest::Test
  ROOT = File.expand_path('../..', __dir__)
  # The generated sources named here are in build/gen.
  Erx::Generated.ensure(root: ROOT)
  SOURCES = [Erx::Generated.path('erlang/apps/erx/src/erx_text_tables.erl', root: ROOT),
             *%w[erlang/apps/erx/src/erx_text.erl erlang/apps/erx/src/erx_source.erl erlang/apps/erx/src/erx.erl
                 test/erlang/erx_source_tests.erl].map { |path| File.join(ROOT, path) }].freeze

  def test_source_cases_pass_under_eunit
    Dir.mktmpdir('erx-source-test') do |work|
      output, status = Open3.capture2e(ENV.fetch('ERX_ERLC'), '-Werror', '-o', work, *SOURCES, stdin_data: '')
      assert status.success?, output

      output, status = Open3.capture2e('gtimeout', '-k', '10', '300', ENV.fetch('ERX_ERL'), '-noshell', '-pa', work,
                                       '-eval', 'halt(case eunit:test(erx_source_tests) of ok -> 0; _ -> 1 end).',
                                       chdir: work, stdin_data: '')
      assert status.success?, output
      assert_match(/All \d+ tests passed/, output)
    end
  end
end
