# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'minitest/autorun'
require 'open3'
require 'tmpdir'
require_relative '../fixtures/erlang_build'

# erx_pipe_srv, the process that performs erx_pipe:step/2's actions
# (docs/design-pipes.md, "The pipe server"), against a fake pipe NIF:
# test/erlang/erx_pipe_srv_tests.erl. Each seeded fault of the server must
# fail the EUnit case named beside it.
class ErxPipeSrvTest < Minitest::Test
  ROOT = File.expand_path('../..', __dir__)
  # The application, compiled whole (ErlangBuild); the fake NIF and the suite; the server,
  # whose text the seeded faults replace.
  APPLICATIONS = %w[erx].freeze
  TESTS = %w[test/erlang/erx_pipe_fake_nif.erl test/erlang/erx_pipe_srv_tests.erl].freeze
  SERVER = 'erlang/apps/erx/src/erx_pipe_srv.erl'

  def test_the_server_performs_the_steps
    text, ok = run_eunit(File.read(File.join(ROOT, SERVER)))
    assert ok, text
    assert_match(/All \d+ tests passed/, text)
  end

  # A seeded fault, the EUnit case that must catch it, and the edit that plants it.
  MUTANTS = {
    'a report sent before its holder\'s end has it' =>
      ['report_applied_before_it_is_sent',
       "case {Nif:apply(EndRes, resolve(Report, S)), erx_pipe:copies(Report)} of\n",
       "case {(Pid ! {pipe_report, Report}) =/= x andalso Nif:apply(EndRes, resolve(Report, S)), " \
       "erx_pipe:copies(Report)} of\n"],
    'the objects of a failed step left open' =>
      ['failed_make_undoes_the_step', 'lists:foreach(fun(Obj) -> (S#srv.nif):close(Obj) end, Made),', '_ = Made,'],
    'an end forgotten on another process\'s notice' =>
      ['forged_notice_changes_nothing', '#{{Pipe, End} := {Pid, _}} ->', '_ when is_pid(Pid) ->'],
    # docs/design-pipes.md, Verification, program holders: the speaks-for check skipped.
    'an event run for a process that does not speak for its program' =>
      ['an_event_from_a_non_speaker_is_refused', "{ok, Caller} -> forwarded(Event, Program, From, S);",
       "_ -> forwarded(Event, Program, From, S); % seeded"],
    # The same: a restarted server that numbers from 1, refused by the NIF.
    'a restarted server numbering from 1' =>
      ['a_restarted_server_numbers_above_its_predecessor', 'First = Nif:pipes_made() + 1,', 'First = 1,']
  }.freeze

  def test_seeded_faults_are_caught
    source = File.read(File.join(ROOT, SERVER))
    MUTANTS.each do |name, (expected, original, replacement)|
      assert_equal 1, source.scan(original).size, "mutant #{name} must edit exactly one place"
      text, ok = run_eunit(source.sub(original) { replacement })
      refute ok, "seeded fault not caught: #{name}"
      assert_match(/#{expected}/, text, "seeded fault not caught by its case: #{name}")
    end
  end

  private

  # The cases' text and whether they passed, with the server compiled from server's text.
  def run_eunit(server)
    Dir.mktmpdir('erx-pipe-srv-test') do |work|
      ErlangBuild.compile(work, applications: APPLICATIONS, tests: TESTS, replaced: { SERVER => server })
      eval_text = 'halt(case eunit:test(erx_pipe_srv_tests, [verbose]) of ok -> 0; _ -> 1 end).'
      text, status = Open3.capture2e('gtimeout', '-k', '10', '120', ENV.fetch('ERX_ERL'), '-noshell',
                                     '-pa', work, '-eval', eval_text, chdir: work, stdin_data: '')
      [text, status.success?]
    end
  end
end
