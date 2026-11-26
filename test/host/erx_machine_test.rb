# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'minitest/autorun'
require 'open3'
require 'tmpdir'
require_relative '../fixtures/erlang_build'

# Runs test/erlang/erx_machine_tests.erl, the EUnit cases of the machine tree
# (erx_machine_fs) and the coordinator of the machine's end (erx_machine): the ctl
# parse, the tree's answers, its own mount in the system domain's namespace and the
# coordinator's one entry, against erx, erx_files
# and erx_domain compiled from
# source with warnings as errors on stock's emulator (ERX_ERL and ERX_ERLC,
# which make check supplies). A stand-in takes init's stop, so no case ends the emulator.
class ErxMachineTest < Minitest::Test
  APPLICATIONS = %w[erx erx_files erx_domain].freeze
  # erx_ns_prim_stub stands in for prim_file under the tree's own mount at /machine.
  TESTS = %w[test/erlang/erx_ns_prim_stub.erl
             test/erlang/erx_machine_tests.erl].freeze

  def test_machine_cases_pass_under_eunit
    Dir.mktmpdir('erx-machine-test') do |work|
      ErlangBuild.compile(work, applications: APPLICATIONS, tests: TESTS)

      output, status = Open3.capture2e('gtimeout', '-k', '10', '120', ENV.fetch('ERX_ERL'), '-noshell', '-pa', work,
                                       '-eval', 'halt(case eunit:test(erx_machine_tests) of ok -> 0; _ -> 1 end).',
                                       chdir: work, stdin_data: '')
      assert status.success?, output
      assert_match(/All \d+ tests passed/, output)
    end
  end
end
