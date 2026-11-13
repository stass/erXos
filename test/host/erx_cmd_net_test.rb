# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'minitest/autorun'
require 'open3'
require 'tmpdir'
require_relative '../fixtures/erlang_build'

# Runs test/erlang/erx_cmd_net_tests.erl, the EUnit cases of the command shell's
# `ifconfig` and `ping` (docs/design-shell.md, "Commands"), against the erx_shell
# application compiled from source with warnings as errors on stock's emulator (ERX_ERL
# and ERX_ERLC, which make check supplies). Then a seeded fault: ping counting a reply
# whose sequence number only shares its slot with a request it sent must fail the
# matching case.
class ErxCmdNetTest < Minitest::Test
  ROOT = File.expand_path('../..', __dir__)
  PING = 'erlang/apps/erx_shell/src/erx_cmd_ping.erl'
  # The applications the commands run in, compiled whole (ErlangBuild), and the cases. ping's
  # loop calls the echo socket's client in erx_net_client, whose socket process the case
  # answers with a stand-in.
  APPLICATIONS = %w[erx erx_net_client erx_shell].freeze
  TESTS = %w[test/erlang/erx_cmd_net_tests.erl].freeze
  SEEDED = ['#{Slot := {Seq, At, Seen}} ->', '#{Slot := {_, At, Seen}} ->'].freeze

  def test_net_command_cases_pass_under_eunit
    output, status = eunit({})
    assert status.success?, output
    assert_match(/All \d+ tests passed/, output)
  end

  def test_seeded_slot_match_without_the_sequence_number_is_caught
    exact, faulty = SEEDED
    text = File.read(File.join(ROOT, PING))
    assert_equal 1, text.scan(exact).size
    output, status = eunit({ PING => text.sub(exact) { faulty } })
    refute status.success?, output
    assert_match(/only_replies_to_remembered_requests_count_test.*failed/, output)
  end

  private

  def eunit(replaced)
    Dir.mktmpdir('erx-cmd-net-test') do |work|
      ErlangBuild.compile(work, applications: APPLICATIONS, tests: TESTS, replaced: replaced)
      Open3.capture2e('gtimeout', '-k', '10', '300', ENV.fetch('ERX_ERL'), '-noshell', '-pa', work,
                      '-eval', 'halt(case eunit:test(erx_cmd_net_tests) of ok -> 0; _ -> 1 end).',
                      chdir: work, stdin_data: '')
    end
  end
end
