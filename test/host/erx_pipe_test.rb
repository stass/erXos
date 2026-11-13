# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'minitest/autorun'
require 'open3'
require 'tmpdir'
require_relative '../fixtures/erlang_build'

# Runs the pipe server's decisions, erx_pipe:step/2 (docs/design-pipes.md,
# "The pipe server"), through their EUnit cases (test/erlang/erx_pipe_tests.erl)
# and their exhaustive exploration (test/erlang/erx_pipe_explore.erl), compiled
# with warnings as errors on stock's emulator (ERX_ERL and ERX_ERLC, which make
# check supplies). The exploration runs to the landing gate's depth, or with
# ERX_PIPE_EXPLORE_DEPTH=full to the milestone gate's, as tools/erx check-fuzz
# runs it. Each seeded fault plants one bug in a copy of erx_pipe.erl and
# expects the exploration to fail on the property that guards it.
class ErxPipeTest < Minitest::Test
  ROOT = File.expand_path('../..', __dir__)
# The application holding erx_pipe, compiled whole (ErlangBuild), and the suites.
APPLICATIONS = %w[erx].freeze
MODULE = 'erlang/apps/erx/src/erx_pipe.erl'
TESTS = %w[erx_pipe_tests erx_pipe_explore erx_pipe_explore_tests].map { |name| "test/erlang/#{name}.erl" }.freeze

  # The depth a seeded run explores to; each seed is caught well within it.
  SEED_DEPTH = '5'
  # The deadline of one EUnit run, in seconds: longer when ERX_PIPE_EXPLORE_DEPTH
  # chooses a depth past the landing gate's.
  DEADLINE = ENV.key?('ERX_PIPE_EXPLORE_DEPTH') ? '800' : '280'

  def test_the_cases_and_the_exploration_pass
    output = run_eunit(File.read(File.join(ROOT, MODULE)))
    assert output.success?, output.text
    assert_match(/All \d+ tests passed/, output.text)
  end

  # docs/design-pipes.md's seed: one reader never hears that a writer went,
  # so it would wait for the end of the stream for good.
  def test_a_reader_not_told_of_a_gone_writer_is_caught
    assert_caught("               || {_, #reader{end_id = E, holder = H}} <- Readers],\n",
                  "               || {Rix0, #reader{end_id = E, holder = H}} <- Readers, Rix0 =/= 1],\n",
                  /readers_know_writers/)
  end

  # PI1: a child's read end recorded under another holder, so end of stream
  # would follow from the wrong party's ends.
  def test_an_end_recorded_under_the_wrong_holder_is_caught
    assert_caught('readers = Readers#{Rix => #reader{end_id = End, holder = Child}}',
                  'readers = Readers#{Rix => #reader{end_id = End, holder = {process, self()}}}', /one_holder/)
  end

  # The end of the stream before the last writer goes: a new read end
  # takes an open writer for gone.
  def test_an_open_writer_handed_out_as_gone_is_caught
    assert_caught('{Wend, Ring, RPage, Size, writer_state(State, {bell, Id, E})}',
                  '{Wend, Ring, RPage, Size, writer_state({gone, State}, {bell, Id, E})}', /readers_know_writers/)
  end

  # A forged or late drained notice accepted: one from a holder of no read
  # end of the pipe, taken as the first read end's.
  def test_a_drained_notice_from_another_holder_is_caught
    assert_caught("        {read, Pipe, Rix} -> drained(S, Pipe, Rix, Wend);\n        _ -> {S, []}\n",
                  "        {read, Pipe, Rix} -> drained(S, Pipe, Rix, Wend);\n" \
                  "        _ -> case maps:find(PipeId, S#state.pipes) of\n" \
                  "                 {ok, P0} -> drained(S, P0, 0, Wend);\n" \
                  "                 error -> {S, []}\n" \
                  "             end\n",
                  /forged_changes_nothing/)
  end

  # PI6: a write end named to its readers before its number is in wends.
  def test_a_write_end_reported_before_wends_is_caught
    assert_caught("               make_bell(Id, End, Child),\n               {store_wends, {lock, Id}, Wend}\n" \
                  "               | Reports] ++ [{reply, {ok, write_descriptor(Pipe, Wend)}}],\n",
                  "               make_bell(Id, End, Child)\n               | Reports] ++ " \
                  "[{store_wends, {lock, Id}, Wend}, {reply, {ok, write_descriptor(Pipe, Wend)}}],\n",
                  /wends_before_install/)
  end

  # A lane past the session's quota: a child's write end made with every
  # lane of the quota in use.
  def test_a_lane_past_the_quota_is_caught
    assert_caught("  when Lanes >= Quota; End > Max ->\n", "  when Lanes > Quota; End > Max ->\n",
                  /refused_only_at_limits|lanes_counted/)
  end

  # A forged notice that changes the records: a closed for an end the
  # holder does not hold burns a pipe number.
  def test_a_forged_closed_that_burns_a_pipe_number_is_caught
    assert_caught("        none -> {S, []};\n        Found -> end_gone(S, Found)\n",
                  "        none -> {S#state{next_pipe = S#state.next_pipe + 1}, []};\n" \
                  "        Found -> end_gone(S, Found)\n",
                  /forged_changes_nothing/)
  end

  # A write end's doorbell closed at its gone, while an install still in
  # progress may name it: with read ends left the server no longer holds
  # it, and with none it is closed twice.
  def test_a_gone_writers_doorbell_closed_before_forget_is_caught
    assert_caught("    forget_if_empty(S1, Pipe, Closes ++ Reports);\n",
                  "    #writer{end_id = End0} = maps:get(Wend, Pipe0#pipe.writers),\n" \
                  "    forget_if_empty(S1, Pipe, [{close, {bell, Id, End0}} | Closes ++ Reports]);\n",
                  /server_holds_exactly|closes_only_live/)
  end

  # A gone read end frees the lock as if it were index 0, so a lock held
  # by a gone reader stays held and every other reader waits for good.
  def test_a_lock_freed_for_the_wrong_reader_is_caught
    assert_caught('[{free_lock, {lock, Id}, Rix}, {close, {bell, Id, End}}',
                  '[{free_lock, {lock, Id}, 0}, {close, {bell, Id, End}}', /lock_freed_by_its_reader/)
  end

  private

  Result = Data.define(:success?, :text)

  # Plants `faulty` in place of `exact`, which must occur once, and expects
  # the exploration to fail on `property`.
  def assert_caught(exact, faulty, property)
    source = File.read(File.join(ROOT, MODULE))
    assert_equal 1, source.scan(exact).size, "seed site not found once: #{exact}"
    output = run_eunit(source.sub(exact) { faulty }, depth: SEED_DEPTH)
    refute output.success?, output.text
    assert_match(/violation,\s*#{property}/, output.text)
  end

  # Compiles `source` in place of erx_pipe with the tests and runs both EUnit modules.
  def run_eunit(source, depth: nil)
    Dir.mktmpdir('erx-pipe-test') do |work|
      ErlangBuild.compile(work, applications: APPLICATIONS, tests: TESTS, replaced: { MODULE => source })
      env = depth ? { 'ERX_PIPE_EXPLORE_DEPTH' => depth } : {}
      eval_text = 'halt(case eunit:test([erx_pipe_tests, erx_pipe_explore_tests]) of ok -> 0; _ -> 1 end).'
      text, status = Open3.capture2e(env, 'gtimeout', '-k', '10', DEADLINE, ENV.fetch('ERX_ERL'), '-noshell',
                                     '-pa', work, '-eval', eval_text, chdir: work, stdin_data: '')
      Result.new(success?: status.success?, text: text)
    end
  end
end
