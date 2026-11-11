# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'minitest/autorun'
require 'open3'
require 'tmpdir'
require_relative '../../tools/lib/erx/generated'

# Runs test/erlang/erx_web_line_tests.erl, the EUnit cases of the session's line to the web
# domain (docs/design-web.md, "Views on the line"), and of the path from a browser's open
# through the relay's connection and the line to an update carrying the machine's record,
# compiled from source with warnings as errors on stock's emulator (ERX_ERL and ERX_ERLC,
# which make check supplies). The export table is the test's stand-in, and so is the
# inspector but in the cases of a domain's processes and of the scope, which ask it itself.
class ErxWebLineTest < Minitest::Test
  ROOT = File.expand_path('../..', __dir__)
  Erx::Generated.ensure(root: ROOT)
  INCLUDE = Erx::Generated.path('erlang/apps/erx/include', root: ROOT)
  # The line, the web domain's connection and relay, and the inspector the
  # scope cases ask, with what the inspector reads its records through.
  SOURCES = [*%w[generated/erx_web_proto generated/erx_schema generated/erx_present erx_text_tables]
               .map { |name| Erx::Generated.path("erlang/apps/erx/src/#{name}.erl", root: ROOT) },
             *%w[erx_files/src/erx_procfs_core erx_web_line/src/erx_web_value erx_web_line/src/erx_web_line
                 erx/src/erx_facet erx/src/erx_facets erx/src/erx_driver_ctl erx/src/erx_inspector erx/src/erx_kernel_records
                 erx/src/erx_process_records erx/src/erx_object_info erx/src/erx_log_records
                 erx/src/erx_runtime_records erx/src/erx_text erx_web/src/erx_web_conn
                 erx_web/src/erx_web_relay erx_web/src/erx_web_relay_conn]
               .map { |name| File.join(ROOT, "erlang/apps/#{name}.erl") },
             File.join(ROOT, 'test/erlang/erx_web_line_tests.erl')].freeze

  def test_relay_cases_pass_under_eunit
    Dir.mktmpdir('erx-web-line-test') do |work|
      output, status = Open3.capture2e(ENV.fetch('ERX_ERLC'), '-Werror', '-I', INCLUDE, '-pa', work, '-o', work, *SOURCES, stdin_data: '')
      assert status.success?, output

      output, status = Open3.capture2e('gtimeout', '-k', '10', '300', ENV.fetch('ERX_ERL'), '-noshell', '-pa', work,
                                       '-eval', 'halt(case eunit:test(erx_web_line_tests, [verbose]) of ok -> 0; _ -> 1 end).',
                                       chdir: work, stdin_data: '')
      assert status.success?, output
      assert_match(/All \d+ tests passed/, output)
    end
  end
end
