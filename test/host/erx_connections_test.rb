# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'minitest/autorun'
require 'open3'
require 'tmpdir'

# Runs the EUnit cases of a domain's connection agent (docs/design-runtime.md,
# "Connections in ERTS"), test/erlang/erx_connections_tests.erl, compiled with
# warnings as errors on stock's emulator (ERX_ERL and ERX_ERLC, which make check
# supplies): the agent's answers to its domain pid's records over stand-in ports,
# its failure paths and the records it drops.
class ErxConnectionsTest < Minitest::Test
  ROOT = File.expand_path('../..', __dir__)
  SOURCES = [File.join(ROOT, 'erlang/apps/erx/src/erx_connections.erl'),
             File.join(ROOT, 'test/erlang/erx_connections_tests.erl')].freeze

  def test_agent_cases_pass_under_eunit
    Dir.mktmpdir('erx-connections-test') do |work|
      output, status = Open3.capture2e(ENV.fetch('ERX_ERLC'), '-Werror', '-o', work, *SOURCES, stdin_data: '')
      assert status.success?, output

      output, status = Open3.capture2e('gtimeout', '-k', '10', '120', ENV.fetch('ERX_ERL'), '-noshell',
                                       '-pa', work, '-eval',
                                       'halt(case eunit:test(erx_connections_tests, [verbose]) of ok -> 0; _ -> 1 end).',
                                       chdir: work, stdin_data: '')
      assert status.success?, output
      assert_match(/All \d+ tests passed/, output)
    end
  end
end
