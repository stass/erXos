# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'minitest/autorun'
require 'tmpdir'
require_relative '../../tools/lib/erx/oracle'
require_relative '../../tools/lib/erx/oracle_guest'
require_relative '../../tools/lib/erx/oracle_results'

class OracleReporterTest < Minitest::Test
  def test_real_finish_abort_cannot_certify_a_prefix_of_two_selected_jobs
    root = File.expand_path('../..', __dir__)
    oracle = Erx::Oracle.new(root: root)
    runner = Erx::Runner.new(owner_root: root, log_dir: File.join(root, 'build/logs'))
    with_native_runtime(oracle) do |runtime|
      Dir.mktmpdir('erx-selection-') do |directory|
        result = exercise_controller(root: root, oracle: oracle, runner: runner, runtime: runtime,
          directory: directory, mode: 'observed', suite: 'oracle_queue_first_SUITE',
          second_suite: 'oracle_queue_second_SUITE', abort_selection: true)
        report = result.fetch('report')
        refute report.fetch('complete'), 'aborted selected-job prefix was certified complete'
        assert_equal 2, report.fetch('selected_jobs').size
        stock = exercise_controller(root: root, oracle: oracle, runner: runner, runtime: runtime,
          directory: File.join(directory, 'stock'), mode: 'stock', suite: 'oracle_queue_first_SUITE',
          second_suite: 'oracle_queue_second_SUITE', abort_selection: true)
        assert_equal stock.fetch('outcome'), result.fetch('outcome')
        assert_equal ['first'], report.fetch('cases').select { |record| record.fetch('kind') == 'testcase' }
                                              .map { |record| record.fetch('testcase') }
      end
    end
  end

  def test_normal_two_job_selection_finishes_every_declared_job
    controlled_selection(suite: 'oracle_queue_first_SUITE', second_suite: 'oracle_queue_second_SUITE') do |result|
      report = result.fetch('report')
      assert report.fetch('complete'), JSON.generate(report)
      assert_equal 2, report.fetch('selected_jobs').size
      assert report.fetch('selected_jobs').all? { |job| job.fetch('state') == 'completed' }
    end
  end

  def test_worker_setup_failure_is_recorded_before_any_case_starts
    controlled_selection(suite: 'oracle_queue_first_SUITE', mode: 'setup') do |result|
      report = result.fetch('report')
      refute report.fetch('complete')
      assert_equal 1, report.fetch('selected_jobs').size
      refute_equal 'completed', report.fetch('selected_jobs').first.fetch('state')
      assert_empty report.fetch('cases')
      assert report.fetch('selected_jobs').first.fetch('worker')
    end
  end

  def test_whole_suite_skip_has_no_invented_testcase_total
    controlled_selection(suite: 'oracle_suite_skip_SUITE') do |result|
      report = result.fetch('report')
      assert report.fetch('complete'), JSON.generate(report)
      assert_equal 0, report.fetch('counts').fetch('user_skip')
      assert_equal 1, report.fetch('suite_skip_counts').fetch('user_skip')
      marker = report.fetch('cases').find { |record| record['kind'] == 'suite_skip' }
      refute_nil marker
      assert_equal 0, marker.fetch('number')
    end
  end

  def test_aborted_controller_cannot_publish_a_completed_prefix
    root = File.expand_path('../..', __dir__)
    oracle = Erx::Oracle.new(root: root)
    runner = Erx::Runner.new(owner_root: root, log_dir: File.join(root, 'build/logs'))
    with_native_runtime(oracle) do |runtime|
      Dir.mktmpdir('erx-aborted-report-') do |directory|
        result = exercise_controller(root: root, oracle: oracle, runner: runner, runtime: runtime,
                                     directory: directory, mode: 'abort', suite: 'oracle_abort_SUITE')
        report = result.fetch('report')
        refute report.fetch('complete')
        assert report.fetch('partial_events').any? { |record| record['event'] == 'test_done' }
        assert_equal ['first'], report.fetch('cases').reject { |record| record.fetch('configuration') }
                                            .map { |record| record.fetch('testcase') }
        assert_equal 'passed', report.fetch('cases').find { |record| record['testcase'] == 'first' }.fetch('status')
        refute report.fetch('partial_events').any? { |record| record['event'] == 'job_traversed' }
      end
    end
  end

  def test_controller_records_follow_actual_peer_groups_and_preserve_outcomes
    root = File.expand_path('../..', __dir__)
    oracle = Erx::Oracle.new(root: root)
    runner = Erx::Runner.new(owner_root: root, log_dir: File.join(root, 'build/logs'))
    with_native_runtime(oracle) do |runtime|
      Dir.mktmpdir('erx-controller-report-') do |directory|
        stock = exercise_controller(root: root, oracle: oracle, runner: runner, runtime: runtime,
                                    directory: File.join(directory, 'stock'), mode: 'stock')
        observed = exercise_controller(root: root, oracle: oracle, runner: runner, runtime: runtime,
                                       directory: File.join(directory, 'observed'), mode: 'observed')
        broken = exercise_controller(root: root, oracle: oracle, runner: runner, runtime: runtime,
                                     directory: File.join(directory, 'broken'), mode: 'broken')
        assert_equal stock.fetch('outcome'), observed.fetch('outcome')
        assert_equal stock.fetch('outcome'), broken.fetch('outcome')
        report = observed.fetch('report')
        assert report.fetch('complete'), JSON.generate(report)
        peers = report.fetch('cases').select { |record| record.fetch('testcase') == 'peer_case' }
        assert_equal 3, peers.size
        assert_equal [%w[parallel one], %w[parallel three], %w[parallel two]], peers.map { |record| record.fetch('group') }.sort
        observed.fetch('truth').each do |truth|
          record = report.fetch('cases').find { |candidate| candidate['log'] == truth.fetch('log') }
          refute_nil record
          assert_equal truth.fetch('groups'), record.fetch('group')
          assert_equal truth.fetch('testcase'), record.fetch('testcase')
        end
        repeated = report.fetch('cases').select { |record| record.fetch('testcase') == 'repeated' }
        assert_equal 2, repeated.size
        assert_equal 2, repeated.map { |record| record.fetch('groups') }.uniq.size
        assert_equal [1, 2], repeated.map { |record| record.fetch('attempt') }
        timeout_case = report.fetch('cases').find { |record| record.fetch('testcase') == 'timeout' }
        assert_match(/timetrap_timeout/, File.read(timeout_case.fetch('log')))
        refute broken.fetch('report').fetch('complete')
        refute stock.fetch('report').fetch('complete')
      end
    end
  end

  def test_private_event_handler_does_not_enter_stock_documentation_tests
    root = File.expand_path('../..', __dir__)
    oracle = Erx::Oracle.new(root: root)
    runner = Erx::Runner.new(owner_root: root, log_dir: File.join(root, 'build/logs'))
    Dir.mktmpdir('erx-reporter-') do |directory|
      with_native_runtime(oracle) do |runtime|
        include_path = File.join(runtime.fetch('source'), 'lib/common_test/include')
        runner.run([runtime.fetch('erlc'), *Erx::ContainerOracleJob::REPORTER_FLAGS,
                    '-I', include_path, '-o', directory, File.join(root, 'test/oracle/erx_oracle_events.erl')],
                   name: 'oracle-reporter-docs-compile', deadline: 30, env: Erx::Oracle::CLEAN_ERLANG_ENV)
        expression = 'case code:get_doc(erx_oracle_events) of {error,missing}->halt(0); ' \
                     'Other->io:format("unexpected reporter docs: ~p~n",[Other]),halt(1) end.'
        result = runner.run([runtime.fetch('erl'), '-noshell', '-noinput', '-boot', 'no_dot_erlang',
                             '-pa', directory, '-eval', expression],
                            name: 'oracle-reporter-docs-check', deadline: 30, env: Erx::Oracle::CLEAN_ERLANG_ENV)
        assert_equal 'succeeded', result.fetch('state')
      end
    end
  end

  private

  def controlled_selection(suite:, second_suite: nil, mode: 'observed')
    root = File.expand_path('../..', __dir__)
    oracle = Erx::Oracle.new(root: root)
    runner = Erx::Runner.new(owner_root: root, log_dir: File.join(root, 'build/logs'))
    with_native_runtime(oracle) do |runtime|
      Dir.mktmpdir('erx-selected-report-') do |directory|
        yield exercise_controller(root: root, oracle: oracle, runner: runner, runtime: runtime,
          directory: directory, mode: mode, suite: suite, second_suite: second_suite)
      end
    end
  end

  # The aggregate runner already holds the JIT build lock while supplying its
  # verified binaries. Standalone invocation obtains that same build itself.
  def with_native_runtime(oracle)
    source = oracle.source_path('jit')
    if ENV['ERX_ERL'] || ENV['ERX_ERLC']
      runtime = { 'erl' => ENV.fetch('ERX_ERL'), 'erlc' => ENV.fetch('ERX_ERLC'), 'source' => source }
      yield runtime
    else
      oracle.with_runtime('jit') { |runtime| yield runtime.merge('source' => source) }
    end
  end

  def exercise_controller(root:, oracle:, runner:, runtime:, directory:, mode:, suite: 'oracle_identity_SUITE',
                          second_suite: nil, abort_selection: false)
    FileUtils.mkdir_p(directory)
    logs = File.join(directory, 'ct-logs')
    truth = File.join(directory, 'truth')
    FileUtils.mkdir_p([logs, truth])
    fixture = File.join(root, 'test/fixtures', suite + '.erl')
    first = second_suite ? File.join(directory, 'first') : directory
    second = second_suite && File.join(directory, 'second')
    FileUtils.mkdir_p([first, second].compact)
    FileUtils.cp(fixture, first)
    FileUtils.cp(File.join(root, 'test/fixtures', second_suite + '.erl'), second) if second
    common_test = File.join(runtime.fetch('source'), 'lib/common_test')
    source = mode == 'stock' ? File.join(common_test, 'src/test_server_ctrl.erl') :
                              File.join(root, 'test/oracle/common_test/test_server_ctrl.erl')
    helper = File.join(root, 'test/oracle/erx_oracle_observer.erl')
    extra_helpers = []
    if mode == 'broken'
      helper = File.join(directory, 'erx_oracle_observer.erl')
      File.write(helper, "-module(erx_oracle_observer).\n-export([start/6,finish/3,controller/2,worker/1,traversal/0]).\n" \
                         "start(_,_,_,_,_,_) -> error(observer_failed).\nfinish(_,_,_) -> error(observer_failed).\n" \
                         "controller(_,_) -> error(observer_failed).\nworker(_) -> error(observer_failed).\ntraversal() -> error(observer_failed).\n")
    elsif %w[abort setup].include?(mode)
      worker = File.join(directory, 'erx_oracle_observer_worker.erl')
      File.write(worker, File.read(helper).sub('-module(erx_oracle_observer).', '-module(erx_oracle_observer_worker).'))
      extra_helpers << worker
      helper = File.join(directory, 'erx_oracle_observer.erl')
      control = "controller(A,B) -> erx_oracle_observer_worker:controller(A,B).\n"
      worker = mode == 'setup' ? 'worker(A) -> erx_oracle_observer_worker:worker(A), exit(self(),kill).' :
                                'worker(A) -> erx_oracle_observer_worker:worker(A).'
      finishing = mode == 'abort' ? 'case N of 1 -> exit(self(),kill); _ -> ok end.' : 'ok.'
      File.write(helper, "-module(erx_oracle_observer).\n-export([start/6,finish/3,controller/2,worker/1,traversal/0]).\n" \
        "start(A,B,C,D,E,F) -> erx_oracle_observer_worker:start(A,B,C,D,E,F).\n" \
        "#{control}" \
        "#{worker}\ntraversal() -> erx_oracle_observer_worker:traversal().\n" \
        "finish(A,B,N) -> erx_oracle_observer_worker:finish(A,B,N),\n" \
        "#{finishing}\n")
    end
    environment = Erx::Oracle::CLEAN_ERLANG_ENV.merge('ERX_GROUND_TRUTH' => truth,
                    'ERX_ORACLE_EVENTS' => File.join(directory, 'events.jsonl'),
                    'ERX_FIXTURE_DIR' => directory, 'ERX_FIXTURE_LOGS' => logs,
                    'ERX_ABORT_SELECTION' => abort_selection.to_s,
                    'ERX_JOB_FIRST' => first, 'ERX_JOB_SECOND' => second)
    runner.run([runtime.fetch('erlc'), *Erx::ContainerOracleJob::REPORTER_FLAGS, '+nowarn_deprecated_catch',
                '-I', File.join(common_test, 'include'), '-I', File.join(common_test, 'src'),
                '-o', directory, source, helper, *extra_helpers, File.join(root, 'test/oracle/erx_oracle_events.erl'),
                *(!second_suite ? [File.join(first, suite + '.erl')] : [])],
               name: "oracle-controller-compile-#{mode}", deadline: 30, env: environment)
    if second_suite
      [[first, suite], [second, second_suite]].each do |folder, name|
        runner.run([runtime.fetch('erlc'), *Erx::ContainerOracleJob::REPORTER_FLAGS, '-o', folder,
                    File.join(folder, name + '.erl')], name: 'oracle-queued-fixture', deadline: 30, env: environment)
      end
    end
    selection = second_suite ? '{dir,[os:getenv("ERX_JOB_FIRST"),os:getenv("ERX_JOB_SECOND")]},' :
                               "{dir,os:getenv(\"ERX_FIXTURE_DIR\")},{suite,#{suite}},"
    expression = "R=ct:run_test([#{selection}" \
                 '{auto_compile,false},{logdir,os:getenv("ERX_FIXTURE_LOGS")},' \
                 '{event_handler,erx_oracle_events},{ct_hooks,[cth_surefire]}]),' \
                 'ok=file:write_file(filename:join(os:getenv("ERX_FIXTURE_DIR"),"outcome.txt"),' \
                 'io_lib:format("~p",[R])),halt(0).'
    runner.run([runtime.fetch('erl'), '+S', '2', '+SDcpu', '1', '+SDio', '1',
                '-noshell', '-noinput', '-boot', 'no_dot_erlang', '-pa', directory, '-eval', expression],
               name: "oracle-controller-run-#{mode}", deadline: 120, env: environment)
    xml = Dir.glob(File.join(logs, '**/junit_report.xml')).first
    { 'outcome' => File.read(File.join(directory, 'outcome.txt')),
      'report' => Erx::OracleResults.read(xml: xml, events: File.join(directory, 'events.jsonl'),
                                        command: { 'state' => 'succeeded' }),
      'truth' => Dir.glob(File.join(truth, '*.json')).map { |path| JSON.parse(File.read(path)) } }
  end
end
