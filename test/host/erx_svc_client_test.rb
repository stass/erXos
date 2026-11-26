# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'minitest/autorun'
require 'open3'
require 'tmpdir'
require_relative '../fixtures/erlang_build'

# Runs test/erlang/erx_svc_client_tests.erl, the EUnit cases of erx_svc_client
# (docs/design-app-trees.md, "Reading with a deadline", AT6), against the client
# compiled with TEST over a stub tree served by a test process, on stock's emulator
# (ERX_ERL and ERX_ERLC, which make check supplies). Each seeded fault is a client the
# design's verification names, and the case it breaks.
class ErxSvcClientTest < Minitest::Test
  ROOT = File.expand_path('../..', __dir__)
  APPLICATIONS = %w[erx erx_shell].freeze
  TESTS = %w[test/erlang/erx_svc_client_tests.erl].freeze
  CLIENT = 'erlang/apps/erx/src/erx_svc_client.erl'

  # A seeded client: what the fault does, the text of the client it replaces, its
  # replacement, and the EUnit case it fails.
  Seed = Data.define(:fault, :text, :replacement, :failing)
  SEEDS = [
    ['reads at most Max bytes', 'read_all(Files, Fd, Max + 1, [])', 'read_all(Files, Fd, Max, [])',
     'a_long_status_reads_one_byte_past_max_test'],
    ['joins File unchecked', 'case is_name(Name) andalso is_file(File) of', 'case is_name(Name) of',
     'a_name_or_file_that_leaves_the_tree_opens_nothing_test'],
    ['writes again after the deadline', "commanded(Answer)\n",
     "commanded(case Answer of unknown -> write_ctl(Files, Name, Path, Line); _ -> Answer end)\n",
     'a_command_cut_off_is_unknown_and_not_repeated_test'],
    ['answers eio as {error, eio}', "commanded({error, eio}) -> unknown;\n", '',
     'a_command_whose_handler_acts_and_ends_is_unknown_test'],
    ['leaves the reader running at the deadline', "    exit(Pid, kill),\n", '',
     'a_hung_server_times_out_at_the_deadline_test'],
    ['does not link the reader to its caller', '[link, monitor]', '[monitor]',
     'the_callers_end_ends_the_reader_test'],
    ['takes no bound on Deadline', 'D =< ?ERX_SVC_WAIT_MAX', 'true',
     'a_bound_past_the_interfaces_limits_is_refused_test'],
    ['writes a line past svc_ctl_max', 'byte_size(Line) > ?ERX_SVC_CTL_MAX', 'false',
     'a_line_past_svc_ctl_max_is_refused_unwritten_test']
  ].map { |fields| Seed.new(*fields) }.freeze

  def test_client_cases_pass_under_eunit
    output = eunit(source)
    assert_match(/All \d+ tests passed/, output)
  end

  def test_each_seeded_client_fails_its_case
    SEEDS.each do |seed|
      assert_equal 1, source.scan(seed.text).size, seed.fault
      output = eunit(source.sub(seed.text) { seed.replacement }, passes: false)
      assert_match(/#{seed.failing}[^\n]*\*failed\*/, output, seed.fault)
    end
  end

  private

  def source = File.read(File.join(ROOT, CLIENT))

  def eunit(client, passes: true)
    Dir.mktmpdir('erx-svc-client-test') do |work|
      ErlangBuild.compile(work, applications: APPLICATIONS, tests: TESTS, replaced: { CLIENT => client },
                                defines: %w[TEST])
      output, status = Open3.capture2e('gtimeout', '-k', '10', '120', ENV.fetch('ERX_ERL'), '-noshell', '-pa', work,
                                       '-eval', 'halt(case eunit:test(erx_svc_client_tests, [verbose]) of ok -> 0; _ -> 1 end).',
                                       chdir: work, stdin_data: '')
      assert_equal passes, status.success?, output
      output
    end
  end
end
