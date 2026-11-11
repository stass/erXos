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
# which make check supplies). The inspector and the export table are the test's stand-ins.
class ErxWebLineTest < Minitest::Test
  ROOT = File.expand_path('../..', __dir__)
  Erx::Generated.ensure(root: ROOT)
  INCLUDE = Erx::Generated.path('erlang/apps/erx/include', root: ROOT)
  SOURCES = %w[build/gen/erlang/apps/erx/src/generated/erx_web_proto.erl build/gen/erlang/apps/erx/src/generated/erx_schema.erl
               build/gen/erlang/apps/erx/src/generated/erx_present.erl erlang/apps/erx_files/src/erx_procfs_core.erl
               erlang/apps/erx_web_line/src/erx_web_value.erl erlang/apps/erx_web_line/src/erx_web_line.erl
               erlang/apps/erx/src/erx_facet.erl
               erlang/apps/erx/src/erx_driver_ctl.erl erlang/apps/erx_web/src/erx_web_conn.erl
               erlang/apps/erx_web/src/erx_web_relay.erl erlang/apps/erx_web/src/erx_web_relay_conn.erl
               test/erlang/erx_web_line_tests.erl]
            .map { |path| File.join(ROOT, path) }.freeze

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
