# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'minitest/autorun'
require 'open3'
require 'tmpdir'
require_relative '../../tools/lib/erx/generated'

# Runs test/erlang/erx_web_relay_tests.erl, the EUnit cases of the web domain's relay of
# the host link's web facet (docs/design-web.md, "The host tool's front end"), against
# erx_web_relay, erx_web_relay_conn, erx_web_conn and the generated erx_web_proto,
# compiled from source with warnings as errors on stock's emulator (ERX_ERL and ERX_ERLC,
# which make check supplies). erx_facet is compiled for provide/2 and erx_driver_ctl for
# the mint's check; no case starts a facet, whose export needs erXos's erx_dist.
class ErxWebRelayTest < Minitest::Test
  ROOT = File.expand_path('../..', __dir__)
  Erx::Generated.ensure(root: ROOT)
  INCLUDE = Erx::Generated.path('erlang/apps/erx/include', root: ROOT)
  SOURCES = %w[build/gen/erlang/apps/erx/src/generated/erx_web_proto.erl erlang/apps/erx/src/erx_facet.erl
               erlang/apps/erx/src/erx_driver_ctl.erl erlang/apps/erx_web/src/erx_web_conn.erl
               erlang/apps/erx_web/src/erx_web_relay.erl erlang/apps/erx_web/src/erx_web_relay_conn.erl
               test/erlang/erx_web_relay_tests.erl]
            .map { |path| File.join(ROOT, path) }.freeze

  def test_relay_cases_pass_under_eunit
    Dir.mktmpdir('erx-web-relay-test') do |work|
      output, status = Open3.capture2e(ENV.fetch('ERX_ERLC'), '-Werror', '-I', INCLUDE, '-pa', work, '-o', work, *SOURCES, stdin_data: '')
      assert status.success?, output

      output, status = Open3.capture2e('gtimeout', '-k', '10', '300', ENV.fetch('ERX_ERL'), '-noshell', '-pa', work,
                                       '-eval', 'halt(case eunit:test(erx_web_relay_tests, [verbose]) of ok -> 0; _ -> 1 end).',
                                       chdir: work, stdin_data: '')
      assert status.success?, output
      assert_match(/All \d+ tests passed/, output)
    end
  end
end
