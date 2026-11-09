# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'minitest/autorun'
require 'open3'
require 'tmpdir'
require_relative '../../tools/lib/erx/generated'

# Runs test/erlang/erx_web_value_tests.erl, the EUnit cases of the web
# protocol's projection of inspection records (docs/design-web.md, "Values"),
# against erx_web_value and the modules it calls, compiled from source with
# warnings as errors on stock's emulator (ERX_ERL and ERX_ERLC, which make
# check supplies).
class ErxWebValueTest < Minitest::Test
  ROOT = File.expand_path('../..', __dir__)
  Erx::Generated.ensure(root: ROOT)
  SOURCES = %w[build/gen/erlang/apps/erx/src/generated/erx_schema.erl build/gen/erlang/apps/erx/src/generated/erx_present.erl
               erlang/apps/erx_files/src/erx_procfs_core.erl
               erlang/apps/erx_web/src/erx_web_value.erl test/erlang/erx_web_value_tests.erl]
            .map { |path| File.join(ROOT, path) }.freeze

  def test_value_cases_pass_under_eunit
    Dir.mktmpdir('erx-web-value-test') do |work|
      output, status = Open3.capture2e(ENV.fetch('ERX_ERLC'), '-Werror', '-o', work, *SOURCES, stdin_data: '')
      assert status.success?, output

      output, status = Open3.capture2e('gtimeout', '-k', '10', '300', ENV.fetch('ERX_ERL'), '-noshell', '-pa', work,
                                       '-eval', 'halt(case eunit:test(erx_web_value_tests) of ok -> 0; _ -> 1 end).',
                                       chdir: work, stdin_data: '')
      assert status.success?, output
      assert_match(/All \d+ tests passed/, output)
    end
  end
end
