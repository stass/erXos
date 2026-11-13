# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'minitest/autorun'
require 'open3'
require 'tmpdir'
require_relative '../fixtures/erlang_build'

# Runs the EUnit cases of the inspector on stock's emulator (ERX_ERL and ERX_ERLC, which
# make check supplies): erx_kernel_records' pure core (test/erlang/erx_kernel_records_tests.erl),
# the process records, scopes and renderers (test/erlang/erx_inspector_tests.erl), the start
# table's records (test/erlang/erx_app_records_tests.erl), the runtime
# agent and the query worker
# (test/erlang/erx_inspect_agent_tests.erl, erx_inspect_worker_tests.erl), against
# the applications compiled whole (ErlangBuild). erx_object_info is compiled but its NIF is
# never loaded: the cases reach the kernel only through the pure core.
class ErxInspectorTest < Minitest::Test
  ROOT = File.expand_path('../..', __dir__)
  # The applications the suites exercise, compiled whole (ErlangBuild), and the suites.
  APPLICATIONS = %w[erx erx_shell].freeze
  TESTS = %w[erx_kernel_records erx_inspector erx_app_records erx_inspect_agent erx_inspect_worker
             erx_inspect_facet].map { |name| "test/erlang/#{name}_tests.erl" }.freeze
  ERX = 'erlang/apps/erx'

  # Each fault replaces one passage of one source, and the case it names must fail.
  Fault = Data.define(:name, :file, :from, :to, :tests, :caught_by)
  AGENT = File.join(ERX, 'src/erx_inspect_agent.erl')
  WORKER = File.join(ERX, 'src/erx_inspect_worker.erl')
  INSPECTOR = File.join(ERX, 'src/erx_inspector.erl')
  QUERY = File.join(ERX, 'src/erx_inspect_query.erl')
  FACET = File.join(ERX, 'src/erx_inspect_facet.erl')
  APP_RECORDS = File.join(ERX, 'src/erx_app_records.erl')
  # The logger's default handler is configured to write to standard error, so a report a case
  # provokes, such as a process's crash at its maximum heap size, cannot land inside EUnit's
  # line for that case, which names the case and ends with its verdict.
  LOGGER_TO_STDERR = '[{handler, default, logger_std_h, #{config => #{type => standard_error}}}]'
  # An EUnit run: whether it passed, EUnit's report alone (standard output), and the run's
  # whole text, both streams, for messages.
  EunitRun = Data.define(:passed, :report, :text)
  FAULTS = [
    Fault.new(name: 'a down row shown with no reason', file: APP_RECORDS,
              from: 'state(enabled, down) -> {down, unknown};', to: 'state(enabled, down) -> {down, {ok, <<>>}};',
              tests: 'erx_app_records_tests', caught_by: 'a_down_rows_reason_is_unknown_test'),
    Fault.new(name: 'a refused row shown with no reason', file: APP_RECORDS,
              from: 'state({refused, Refusal}, _Run) -> {refused, {ok, refusal(Refusal)}};',
              to: 'state({refused, _Refusal}, _Run) -> _ = fun refusal/1, {refused, {ok, <<>>}};',
              tests: 'erx_app_records_tests', caught_by: 'each_state_is_shown_test_'),
    Fault.new(name: 'an agent that answers any origin', file: AGENT,
              from: 'handle({erx_origin, SystemId, {erx_inspect_ask, Alias, Query}}, Self, SystemId) when',
              to: 'handle({erx_origin, _Origin, {erx_inspect_ask, Alias, Query}}, Self, _SystemId) when',
              tests: 'erx_inspect_agent_tests', caught_by: 'answers_only_the_system_domain_test'),
    Fault.new(name: 'an agent that takes exactly [processes, Pid]', file: AGENT,
              from: 'owns([processes, {pid, Self, _Number, _Serial} | _], Self) -> true;',
              to: 'owns([processes, {pid, Self, _Number, _Serial}], Self) -> true;',
              tests: 'erx_inspect_agent_tests', caught_by: 'answers_paths_below_its_processes_test'),
    Fault.new(name: 'a worker that asks every domain before it builds the page', file: WORKER,
              from: '{Listing, Page} = lists:foldl(fun(Other, Acc) -> gather(Other, Acc, Context) end, Start, Others),',
              to: '_ = fun gather/3, Asked = [{Domain, ask(Agent, Domain, {entries, [processes]}, Context)} || {Domain, Agent} <- Others, Agent =/= none], ' \
                  '{Listing, Page} = lists:foldl(fun({Domain, A}, Acc) -> merge(Domain, A, Acc, Context) end, Start, Asked),',
              tests: 'erx_inspect_worker_tests', caught_by: 'eight_domains_give_one_page'),
    Fault.new(name: 'a worker that takes its answer by a selective receive', file: WORKER,
              from: "            exit(normal);\n        _Dropped ->\n            case clock() >= Until of\n                true -> unalias(Alias), {timeout, Status};\n                false -> await_answer(Domain, Alias, Owner, Until, Status)\n            end\n",
              to: "            exit(normal)\n",
              tests: 'erx_inspect_worker_tests', caught_by: 'flood_leaves_the_answer_whole_test'),
    Fault.new(name: 'a worker with no deadline of its own', file: WORKER,
              from: "    case Until - clock() of\n        Left when Left =< 0 ->",
              to: "    case Until - clock() + 1000000 of\n        Left when Left =< 0 ->",
              tests: 'erx_inspect_worker_tests', caught_by: 'stalled_agents_answer_by_the_deadline_test'),
    Fault.new(name: 'a wait with no deadline', file: WORKER,
              from: 'after max(0, Until - clock()) ->', to: 'after infinity ->',
              tests: 'erx_inspect_worker_tests', caught_by: 'stalled_agents_answer_by_the_deadline_test'),
    Fault.new(name: 'a worker that checks only with validate_record/1', file: WORKER,
              from: '    case IsPath(Path) andalso Path =/= [] andalso Id =:= lists:last(Path) of' + "\n" + '        true -> validated(Record#{attrs := maps:map(fun runtime/2, Attrs)}, Domain);',
              to: '    case is_function(IsPath) andalso Id =/= Attrs of' + "\n" + '        true -> _ = fun runtime/2, validated(Record, Domain);',
              tests: 'erx_inspect_worker_tests', caught_by: 'an_answer_must_agree_with_its_question_test'),
    Fault.new(name: 'the byte cut removed', file: INSPECTOR,
              from: 'case Count < ?ERX_INSPECT_PAGE_MAX andalso Bytes + Size =< ?ERX_INSPECT_REPLY_MAX of',
              to: 'case Count < ?ERX_INSPECT_PAGE_MAX andalso Bytes + Size > 0 of',
              tests: 'erx_inspect_worker_tests', caught_by: 'a_listing_is_cut_by_bytes_test'),
    Fault.new(name: 'an admission path that takes a scope from the options', file: QUERY,
              from: 'map_size(maps:without([offset, limit], Options)) =:= 0 andalso',
              to: 'map_size(maps:without([offset, limit, scope], Options)) >= 0 andalso',
              tests: 'erx_inspect_facet_tests', caught_by: 'a_holder_cannot_widen_its_scope_test'),
    Fault.new(name: 'a scope fixed as a list at the mint', file: FACET,
              from: '    {ok, #{scope => Scope, worker => maps:get(worker, Grant, #{view => fun erx_inspector:view/1})}}.',
              to: '    Worker = maps:get(worker, Grant, #{view => fun erx_inspector:view/1}), ' \
                  '{ok, Fixed} = (maps:get(view, Worker))(Scope), ' \
                  '{ok, #{scope => [Id || {Id, _} <- Fixed], worker => Worker}}.',
              tests: 'erx_inspect_facet_tests', caught_by: 'a_principals_scope_follows_its_domains_test'),
    Fault.new(name: 'a facet that runs its requests in its own process', file: FACET,
              from: '{ok, Query} -> {forward, erx_inspect_worker:serve(self(), Scope, Options), Query, State};',
              to: '{ok, Query} -> {reply, erx_inspect_worker:call(Query, Scope, Options), State};',
              tests: 'erx_inspect_facet_tests', caught_by: 'a_stalled_agent_holds_up_no_other_query_test'),
    Fault.new(name: 'the bound on a path\'s length removed', file: QUERY,
              from: 'path([Segment | Rest], Count, Literals) when Count < ?ERX_INSPECT_PATH_MAX ->',
              to: 'path([Segment | Rest], Count, Literals) when is_integer(Count) ->',
              tests: 'erx_inspect_facet_tests', caught_by: 'decoder_refuses_everything_else_test')
  ].freeze

  def test_kernel_record_cases_pass_under_eunit
    eunit('erx_kernel_records_tests')
  end

  def test_inspector_cases_pass_under_eunit
    eunit('erx_inspector_tests')
  end

  def test_start_table_record_cases_pass_under_eunit
    eunit('erx_app_records_tests')
  end

  def test_runtime_agent_cases_pass_under_eunit
    eunit('erx_inspect_agent_tests')
  end

  def test_query_worker_cases_pass_under_eunit
    eunit('erx_inspect_worker_tests')
  end

  def test_inspect_facet_cases_pass_under_eunit
    eunit('erx_inspect_facet_tests')
  end

  def test_the_cases_catch_each_seeded_fault
    FAULTS.each do |fault|
      source = File.read(File.join(ROOT, fault.file))
      assert_includes source, fault.from, fault.name
      run = eunit_run(fault.tests, replaced: { fault.file => source.sub(fault.from, fault.to) })
      refute run.passed, "#{fault.name} passed:\n#{run.text}"
      assert_match(/#{fault.caught_by}[^\n]*\*(failed|timed out)\*/, run.report, "#{fault.name}:\n#{run.text}")
    end
  end

  private

  def eunit(suite)
    run = eunit_run(suite)
    assert run.passed, run.text
    assert_match(/All \d+ tests passed/, run.report)
  end

  # Compiles the applications and the suites, with replaced as ErlangBuild.compile takes it,
  # and runs Suite's cases (EunitRun).
  def eunit_run(suite, replaced: {})
    Dir.mktmpdir('erx-inspector-test') do |work|
      ErlangBuild.compile(work, applications: APPLICATIONS, tests: TESTS, replaced: replaced)
      report, errors, status = Open3.capture3('gtimeout', '-k', '10', '120', ENV.fetch('ERX_ERL'), '-noshell',
                                              '-kernel', 'logger', LOGGER_TO_STDERR, '-pa', work,
                                              '-eval', "halt(case eunit:test(#{suite}, [verbose]) of ok -> 0; _ -> 1 end)",
                                              chdir: work, stdin_data: '')
      EunitRun.new(passed: status.success?, report: report, text: "#{report}\n--- standard error ---\n#{errors}")
    end
  end
end
