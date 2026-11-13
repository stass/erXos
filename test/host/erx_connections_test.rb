# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'minitest/autorun'
require 'open3'
require 'tmpdir'
require_relative '../fixtures/erlang_build'
require_relative '../../tools/lib/erx/host_os'

# Runs the EUnit cases of a domain's connection agent (docs/design-runtime.md,
# "Connections in ERTS"), test/erlang/erx_connections_tests.erl, compiled with
# warnings as errors on stock's emulator (ERX_ERL and ERX_ERLC, which make check
# supplies): the agent's answers to its domain pid's records over stand-in ports,
# its failure paths and the records it drops. erx_area's NIF is the host stand-in
# (test/display/erx_area_stand_in.c), so a case can hold a real area resource.
class ErxConnectionsTest < Minitest::Test
  APPLICATIONS = %w[erx].freeze
  TESTS = %w[test/erlang/erx_connections_tests.erl].freeze
  ROOT = File.expand_path('../..', __dir__)
  AREA_STAND_IN = 'test/display/erx_area_stand_in.c'

  def test_agent_cases_pass_under_eunit
    Dir.mktmpdir('erx-connections-test') do |work|
      ErlangBuild.compile(work, applications: APPLICATIONS, tests: TESTS)
      area_nif(work)

      output, status = Open3.capture2e(Erx::HostOs.nif_search_environment(work), 'gtimeout', '-k', '10', '120', ENV.fetch('ERX_ERL'), '-noshell',
                                       '-pa', work, '-eval',
                                       'halt(case eunit:test(erx_connections_tests, [verbose]) of ok -> 0; _ -> 1 end).',
                                       chdir: work, stdin_data: '')
      assert status.success?, output
      assert_match(/All \d+ tests passed/, output)
    end
  end

  private

  # erx_area.so in work, against the headers of the emulator ERX_ERL runs.
  def area_nif(work)
    root, status = Open3.capture2e('gtimeout', '-k', '10', '60', ENV.fetch('ERX_ERL'), '-noshell', '-eval',
                                   'io:put_chars(code:root_dir()), halt().', stdin_data: '')
    assert status.success?, root
    output, status = Open3.capture2e('gtimeout', '-k', '10', '120', ENV.fetch('ERX_CLANG', 'clang'), '-std=c17', '-Wall', '-Werror',
                                     *Erx::HostOs::NIF_LINK_FLAGS, '-DERX_AREA_LOADABLE',
                                     '-I', File.join(root, 'usr/include'),
                                     '-I', File.join(ROOT, 'otp/erts/emulator/nifs/erxos'),
                                     '-o', File.join(work, 'erx_area.so'), File.join(ROOT, AREA_STAND_IN),
                                     stdin_data: '')
    assert status.success?, output
  end
end
