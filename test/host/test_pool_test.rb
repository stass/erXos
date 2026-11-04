# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'fileutils'
require 'minitest/autorun'
require 'tmpdir'
require_relative '../../tools/lib/erx/runner'
require_relative '../../tools/lib/erx/test_pool'

class TestPoolTest < Minitest::Test
  PASSED = "1 runs, 1 assertions, 0 failures, 0 errors, 0 skips\n"
  Call = Data.define(:name, :path, :deadline, :chdir, :env, :overlapped)

  # Stands in for Runner: records each call and how many calls were running
  # at once, and answers from a table of outcomes by test file stem. With a
  # barrier, each of the first N calls waits until N calls are running together (or a
  # generous timeout passes), so overlap is proven by arrival and not by a
  # sleep that a loaded machine could outlast.
  class FakeRunner
    attr_reader :max_running

    def initialize(directory, outcomes: {}, barrier: 0)
      @directory = directory
      @outcomes = outcomes
      @barrier = barrier
      @calls = Queue.new
      @lock = Mutex.new
      @running = 0
      @arrived = 0
      @max_running = 0
    end

    def calls = Array.new(@calls.size) { @calls.pop }

    def run(argv, name:, deadline:, chdir:, env:, cancelled: nil)
      overlapped = @lock.synchronize { @max_running = [@max_running, @running += 1].max; @running }
      @calls << Call.new(name, argv.last, deadline, chdir, env, overlapped)
      wait_for_barrier if @lock.synchronize { (@arrived += 1) <= @barrier }
      outcome = @outcomes.fetch(File.basename(argv.last, '_test.rb'), PASSED)
      raise outcome if outcome.is_a?(Exception)

      log = File.join(@directory, "#{name}.log")
      File.write(log, outcome)
      raise Erx::CommandError, { 'state' => 'failed', 'log' => log } if outcome == :failed

      { 'state' => 'succeeded', 'log' => log }
    ensure
      @lock.synchronize { @running -= 1 }
    end

    private

    def wait_for_barrier
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 20
      sleep(0.01) while @lock.synchronize { @max_running } < @barrier &&
                        Process.clock_gettime(Process::CLOCK_MONOTONIC) < deadline
    end
  end

  def setup
    @directory = Dir.mktmpdir('erx-test-pool-')
  end

  def teardown
    FileUtils.remove_entry(@directory)
  end

  def write_test(stem, text = "# a test\n")
    File.join(@directory, "#{stem}_test.rb").tap { |path| File.write(path, text) }
  end

  def pool(paths, runner, **options)
    Erx::TestPool.run(paths, runner: runner, name: 'host-tests', environment: { 'K' => 'v' }, deadline: 77,
                             root: @directory, **{ pool_size: 4 }.merge(options))
  end

  # Runs the pool expecting a failed step; returns the error and the lines
  # the pool printed for the failed files.
  def failing_pool(paths, runner, **options)
    error = nil
    _out, printed = capture_io { error = assert_raises(Erx::Error) { pool(paths, runner, **options) } }
    [error, printed]
  end

  def test_jobs_default_to_half_the_cpus_and_never_below_one
    assert_equal 8, Erx::TestPool.jobs(environment: {}, cpus: 16)
    assert_equal 1, Erx::TestPool.jobs(environment: {}, cpus: 1)
    assert_equal 1, Erx::TestPool.jobs(environment: { 'ERX_TEST_JOBS' => '' }, cpus: 1)
  end

  def test_jobs_are_overridden_by_a_positive_count_and_other_values_are_refused
    assert_equal 3, Erx::TestPool.jobs(environment: { 'ERX_TEST_JOBS' => '3' }, cpus: 16)
    ['0', '-1', '2x', ' 2', '1.5', '257', '99999'].each do |bad|
      error = assert_raises(Erx::Error, bad) { Erx::TestPool.jobs(environment: { 'ERX_TEST_JOBS' => bad }) }
      assert_includes error.message, 'ERX_TEST_JOBS'
    end
  end

  def test_every_file_runs_once_with_its_own_name_deadline_and_environment
    paths = %w[alpha beta_two Gamma.x].map { |stem| write_test(stem) }
    runner = FakeRunner.new(@directory)
    verdicts = pool(paths, runner)
    assert_equal paths, verdicts.map(&:path)
    assert(verdicts.all? { |verdict| verdict.failure.nil? })
    calls = runner.calls
    assert_equal paths.sort, calls.map(&:path).sort
    assert_equal %w[host-tests-alpha host-tests-beta_two host-tests-gamma-x], calls.map(&:name).sort
    assert(calls.all? { |call| call.deadline == 77 && call.chdir == @directory && call.env == { 'K' => 'v' } })
  end

  def test_files_overlap_up_to_the_pool_size_and_no_further
    paths = Array.new(8) { |index| write_test("file#{index}") }
    runner = FakeRunner.new(@directory, barrier: 3)
    pool(paths, runner, pool_size: 3)
    assert_equal 3, runner.max_running
  end

  def test_a_pool_of_one_runs_files_one_at_a_time
    paths = Array.new(4) { |index| write_test("file#{index}") }
    runner = FakeRunner.new(@directory)
    pool(paths, runner, pool_size: 1)
    assert_equal 1, runner.max_running
  end

  def test_a_failing_file_fails_the_step_naming_it_and_the_rest_still_run
    paths = %w[good bad also_good].map { |stem| write_test(stem) }
    runner = FakeRunner.new(@directory, outcomes: { 'bad' => :failed })
    error, printed = failing_pool(paths, runner)
    assert_includes error.message, '1 of 3 test files failed'
    refute_includes error.message, "\n"
    assert_includes printed, "#{paths[1]}: failed; log: "
    refute_includes printed, paths[0]
    assert_equal 3, runner.calls.size
  end

  def test_every_failure_is_reported_not_only_the_first
    paths = %w[one two three].map { |stem| write_test(stem) }
    runner = FakeRunner.new(@directory, outcomes: { 'one' => :failed, 'three' => :failed })
    error, printed = failing_pool(paths, runner, pool_size: 1)
    assert_includes error.message, '2 of 3 test files failed'
    assert_includes printed, paths[0]
    assert_includes printed, paths[2]
    refute_includes printed, paths[1]
  end

  def test_a_file_that_ran_no_tests_is_a_failure_not_a_pass
    {
      "0 runs, 0 assertions, 0 failures, 0 errors, 0 skips\n" => 'ran no tests: 0 runs',
      "3 runs, 0 assertions, 0 failures, 0 errors, 3 skips\n" => 'every test skipped',
      "nothing printed\n" => 'no Minitest summary',
      '' => 'no Minitest summary'
    }.each do |log, reason|
      path = write_test('silent')
      _error, printed = failing_pool([path], FakeRunner.new(@directory, outcomes: { 'silent' => log }))
      assert_includes printed, "#{path}: ran no tests", log
      assert_includes printed, reason
    end
  end

  def test_the_last_summary_decides_and_a_clean_exit_with_failures_does_not_pass
    path = write_test('twice')
    fake_then_zero = "#{PASSED}0 runs, 0 assertions, 0 failures, 0 errors, 0 skips\n"
    _error, printed = failing_pool([path], FakeRunner.new(@directory, outcomes: { 'twice' => fake_then_zero }))
    assert_includes printed, '0 runs'

    failed = "1 runs, 1 assertions, 1 failures, 0 errors, 0 skips\n"
    _error, printed = failing_pool([path], FakeRunner.new(@directory, outcomes: { 'twice' => failed }))
    assert_includes printed, 'summary shows failures'

    pool([path], FakeRunner.new(@directory, outcomes: { 'twice' => "#{failed}#{PASSED}" }))
  end

  def test_a_summary_followed_by_minitests_skip_note_still_counts
    log = "#{PASSED}\nYou have skipped tests. Run with --verbose for details.\n"
    pool([write_test('noted')], FakeRunner.new(@directory, outcomes: { 'noted' => log }))
  end

  def test_a_summary_in_a_noisy_log_still_counts
    noisy = ("noise\n" * 20_000) + PASSED
    pool([write_test('noisy')], FakeRunner.new(@directory, outcomes: { 'noisy' => noisy }))
  end

  def test_an_unexpected_exception_in_one_file_fails_that_file_and_starves_no_other
    paths = %w[boom fine more].map { |stem| write_test(stem) }
    runner = FakeRunner.new(@directory, outcomes: { 'boom' => RuntimeError.new('kaboom') })
    _error, printed = failing_pool(paths, runner, pool_size: 1)
    assert_includes printed, "#{paths[0]}: RuntimeError: kaboom ("
    assert_equal 3, runner.calls.size
  end

  def test_serial_files_run_alone_after_all_the_others
    parallel = Array.new(4) { |index| write_test("p#{index}") }
    serial = [write_test('s0', "# erx-gate: serial\n"), write_test('s1', "x\n  # erx-gate: serial  \n")]
    runner = FakeRunner.new(@directory, barrier: 4)
    verdicts = pool(serial + parallel, runner, pool_size: 4)
    assert_equal serial + parallel, verdicts.map(&:path)
    calls = runner.calls
    serial_calls = calls.select { |call| serial.include?(call.path) }
    assert_equal [1, 1], serial_calls.map(&:overlapped)
    assert_equal 4, calls.map(&:overlapped).max
  end

  def test_a_comment_that_only_resembles_the_declaration_is_not_one
    refute Erx::TestPool.serial?(write_test('plain', "# erx-gate: serialized\n"))
    refute Erx::TestPool.serial?(write_test('plain2', "x = 1 # erx-gate: serial\n"))
  end

  def test_nothing_to_run_and_a_repeated_file_are_refused
    error = assert_raises(Erx::Error) { pool([], FakeRunner.new(@directory)) }
    assert_includes error.message, 'no test files'
    path = write_test('twice')
    error = assert_raises(Erx::Error) { pool([path, path], FakeRunner.new(@directory)) }
    assert_includes error.message, 'listed twice'
  end

  # The real runner: processes, process groups, deadlines and logs.
  def real_runner
    Erx::Runner.new(owner_root: @directory, log_dir: File.join(@directory, 'logs'))
  end

  def write_minitest_file(stem, body)
    write_test(stem, "require 'minitest/autorun'\nclass #{stem.capitalize}Test < Minitest::Test\n#{body}\nend\n")
  end

  def real_pool(paths, deadline: 60, **options)
    Erx::TestPool.run(paths, runner: real_runner, name: 'host-tests', environment: {}, deadline: deadline,
                             root: @directory, pool_size: paths.size, **options)
  end

  def test_real_processes_pass_with_distinct_logs_and_reports
    paths = Array.new(6) { |index| write_minitest_file("same#{index}", 'def test_x = assert(true)') }
    logs = real_pool(paths).map(&:log)
    assert_equal logs.uniq.size, logs.size
    assert_equal 6, Dir.glob(File.join(@directory, 'logs/*.json')).size
  end

  def test_a_real_file_that_overruns_its_deadline_is_named_as_timed_out
    hung = write_minitest_file('hung', 'def test_h = sleep(60)')
    _error, printed = failing_pool_real([hung], deadline: 2)
    assert_includes printed, "#{hung}: timed_out; log: "
  end

  def test_real_failing_and_empty_files_fail_by_name
    failing = write_minitest_file('wrong', 'def test_w = assert_equal(1, 2)')
    empty = write_test('empty', "# nothing to run\n")
    _error, printed = failing_pool_real([failing, empty])
    assert_includes printed, "#{failing}: failed"
    assert_includes printed, "#{empty}: ran no tests"
  end

  def test_a_real_file_that_aborts_after_a_good_summary_fails
    body = "def test_a = assert(true)\nend\nMinitest.after_run { Process.kill('KILL', Process.pid) }\nclass Unused"
    aborting = write_minitest_file('aborting', body)
    _error, printed = failing_pool_real([aborting])
    assert_includes printed, "#{aborting}: failed"
  end

  def test_an_interrupt_while_files_run_leaves_no_child_behind
    pidfile = File.join(@directory, 'child.pid')
    hung = write_minitest_file('hung', "def test_h\n File.write(#{pidfile.dump}, Process.pid.to_s)\n sleep(60)\n end")
    runner = real_runner
    interrupter = Thread.new do
      sleep(0.05) until File.exist?(pidfile) && !File.read(pidfile).empty?
      Thread.main.raise(Interrupt)
    end
    assert_raises(Interrupt) do
      Erx::TestPool.run([hung], runner: runner, name: 'host-tests', environment: {}, deadline: 60,
                                root: @directory, pool_size: 1)
    end
    interrupter.join
    pid = File.read(pidfile).to_i
    gone = 100.times.any? do
      Process.kill(0, pid)
      sleep(0.05)
      false
    rescue Errno::ESRCH
      true
    end
    assert gone, 'the test process outlived the interrupted pool'
  end

  def failing_pool_real(paths, **options)
    error = nil
    _out, printed = capture_io { error = assert_raises(Erx::Error) { real_pool(paths, **options) } }
    [error, printed]
  end
end
