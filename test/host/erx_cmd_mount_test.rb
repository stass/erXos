# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'minitest/autorun'
require 'open3'
require 'tmpdir'
require_relative '../fixtures/erlang_build'

# Runs test/erlang/erx_cmd_mount_tests.erl, the EUnit cases of the command
# shell's `mount` (docs/design-files.md, "Building, binding and mounting"),
# against the erx_shell application and the file servers whose statfs it
# names, compiled from source with warnings as errors on stock's emulator
# (ERX_ERL and ERX_ERLC, which make check supplies). The `p9_magic_` values
# come from the generated erx_abi.hrl in build/gen.
class ErxCmdMountTest < Minitest::Test
  # The applications the command and the servers run in, compiled whole (ErlangBuild).
  APPLICATIONS = %w[erx erx_shell erx_files erx_storage].freeze
  TESTS = %w[test/erlang/erx_cmd_mount_tests.erl].freeze

  def test_mount_cases_pass_under_eunit
    Dir.mktmpdir('erx-cmd-mount-test') do |work|
      ErlangBuild.compile(work, applications: APPLICATIONS, tests: TESTS)

      output, status = Open3.capture2e('gtimeout', '-k', '10', '120', ENV.fetch('ERX_ERL'), '-noshell', '-pa', work,
                                       '-eval', 'halt(case eunit:test(erx_cmd_mount_tests) of ok -> 0; _ -> 1 end).',
                                       chdir: work, stdin_data: '')
      assert status.success?, output
      assert_match(/All \d+ tests passed/, output)
    end
  end
end
