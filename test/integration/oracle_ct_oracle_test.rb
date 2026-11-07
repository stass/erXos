# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'minitest/autorun'
require 'fileutils'
require 'json'
require 'tmpdir'
require_relative '../../tools/lib/erx/oracle'
require_relative '../../tools/lib/erx/oracle_guest'

# erx_ct_oracle and erx_oracle_events on stock OTP: what a run leaves in its
# work directory, which on erXos is /tmp under its cap, and how the event
# report survives a refused write.
class OracleCtOracleTest < Minitest::Test
  ROOT = File.expand_path('../..', __dir__)
  # Run in name order: the failing suite's priv_dir goes when the passing
  # one starts, the passing one's when it ends, and the trailing one's,
  # whose init_per_suite fails too, when the run ends.
  CLEANUP_SUITES = %w[oracle_cleanup_failing_SUITE oracle_cleanup_passing_SUITE
                      oracle_cleanup_trailing_SUITE].freeze

  # Each suite's priv_dir is gone once the run ends, also for a suite whose
  # init_per_suite fails, each deletion is noted with the bytes it held,
  # and a suite reads its _data copy.
  def test_run_deletes_each_priv_dir
    with_reporter do |runner, runtime, directory|
      suites = File.join(directory, 'suites')
      FileUtils.mkdir_p(suites)
      CLEANUP_SUITES.each do |suite|
        compile(runner, runtime, File.join(ROOT, 'test/fixtures', suite + '.erl'), suites)
        data = File.join(ROOT, 'test/fixtures', suite + '_data')
        FileUtils.cp_r(data, suites) if File.directory?(data)
      end
      work = File.join(directory, 'work')
      result = runner.run([runtime.fetch('erl'), '-noshell', '-noinput', '-boot', 'no_dot_erlang',
                           '-pa', File.join(directory, 'reporter'), '-run', 'erx_ct_oracle', 'main', suites, work],
                          name: 'oracle-cleanup-run', deadline: 120, chdir: directory,
                          env: Erx::Oracle::CLEAN_ERLANG_ENV)
      assert_equal 'succeeded', result.fetch('state')
      done = File.readlines(File.join(work, 'logs/events.jsonl')).map { |line| JSON.parse(line) }
                 .select { |event| event['event'] == 'tc_done' }
                 .to_h { |event| [[event['suite'], event['testcase']], event['result']] }
      assert_equal 'passed', done.fetch(%w[oracle_cleanup_passing_SUITE reads_data])
      assert_equal 'passed', done.fetch(%w[oracle_cleanup_passing_SUITE writes_priv])
      notes = File.read(result.fetch('log')).scan(/^erx-oracle-note (\S+) priv_dir (\d+)$/)
      assert_equal CLEANUP_SUITES.map { |suite| [suite, '1024'] }, notes
      assert_empty Dir.glob(File.join(work, 'logs/**/log_private'))
      refute_empty Dir.glob(File.join(work, 'logs/ct_run.*/*.logs/run.*/suite.log'))
      assert File.file?(File.join(work, 'suites/oracle_cleanup_failing_SUITE_data/payload.txt'))
    end
  end

  # A write to the event report that fails (here on a closed file; on erXos
  # with enospc on a full /tmp) leaves the handler installed and every event
  # on standard output, in sequence, after one note of the loss.
  def test_refused_report_write_keeps_the_event_stream
    with_reporter do |runner, runtime, directory|
      events = File.join(directory, 'events.jsonl')
      expression = <<~ERLANG.tr("\n", ' ')
        try
          true = os:putenv("ERX_ORACLE_EVENTS", #{events.inspect}),
          {ok, {Device, 0} = S0} = erx_oracle_events:init([]),
          ok = file:close(Device),
          E = {event, test_stats, node(), {1, 0, {0, 0}}},
          {ok, S1} = erx_oracle_events:handle_event(E, S0),
          {ok, _} = erx_oracle_events:handle_event(E, S1),
          halt(0)
        catch C:R:S -> io:format("~p~n", [{C, R, S}]), halt(1)
        end.
      ERLANG
      result = runner.run([runtime.fetch('erl'), '-noshell', '-noinput', '-boot', 'no_dot_erlang',
                           '-pa', File.join(directory, 'reporter'), '-eval', expression],
                          name: 'oracle-events-refused', deadline: 30, env: Erx::Oracle::CLEAN_ERLANG_ENV)
      assert_equal 'succeeded', result.fetch('state'), File.read(result.fetch('log'))
      output = File.read(result.fetch('log'))
      assert_equal %w[0 1], output.scan(/^erx-oracle-event (\d+) /).flatten
      assert_equal 1, output.scan(/^erx-oracle-note event report lost: \S+$/).size
    end
  end

  private

  # The reporter compiled as the oracle compiles it, on the native stock
  # runtime the other reporter tests use.
  def with_reporter
    oracle = Erx::Oracle.new(root: ROOT)
    runner = Erx::Runner.new(owner_root: ROOT, log_dir: File.join(ROOT, 'build/logs'))
    Dir.mktmpdir('erx-ct-oracle-') do |directory|
      with_native_runtime(oracle) do |runtime|
        reporter = File.join(directory, 'reporter')
        FileUtils.mkdir_p(reporter)
        %w[erx_oracle_events.erl erx_ct_oracle.erl].each do |source|
          compile(runner, runtime, File.join(ROOT, 'test/oracle', source), reporter)
        end
        yield runner, runtime, directory
      end
    end
  end

  def compile(runner, runtime, source, out)
    include_path = File.join(runtime.fetch('source'), 'lib/common_test/include')
    runner.run([runtime.fetch('erlc'), *Erx::ContainerOracleJob::REPORTER_FLAGS, '-I', include_path,
                '-o', out, source],
               name: 'oracle-ct-oracle-compile', deadline: 60, env: Erx::Oracle::CLEAN_ERLANG_ENV)
  end

  def with_native_runtime(oracle)
    source = oracle.source_path('jit')
    if ENV['ERX_ERL'] || ENV['ERX_ERLC']
      yield({ 'erl' => ENV.fetch('ERX_ERL'), 'erlc' => ENV.fetch('ERX_ERLC'), 'source' => source })
    else
      oracle.with_runtime('jit') { |runtime| yield runtime.merge('source' => source) }
    end
  end
end
