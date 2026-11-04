# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'etc'
require 'rbconfig'
require_relative 'error'
require_relative 'runner'

module Erx
  # Runs a list of Minitest files, each as its own process with its own log
  # and deadline, a bounded number at a time. One file per process keeps a
  # file's global state, temporary directories and sanitizer aborts out of its
  # neighbours, and a failure names the file and its log.
  #
  # No file goes unaccounted: every path handed in gets a verdict, the
  # verdicts are compared with the input before the step may succeed, and a
  # file passes only if its process exited cleanly and its log's last
  # Minitest summary shows tests that ran, none failed and not all skipped.
  # A file that cannot share the machine with others declares
  # `# erx-gate: serial`; those run alone, after the rest.
  module TestPool
    module_function

    JOBS_VARIABLE = 'ERX_TEST_JOBS'
    MAX_JOBS = 256
    SERIAL_DECLARATION = '# erx-gate: serial'
    SERIAL_PATTERN = /^\s*#{Regexp.escape(SERIAL_DECLARATION)}\s*$/
    SUMMARY = /^(\d+) runs, \d+ assertions, (\d+) failures, (\d+) errors, (\d+) skips$/
    # A summary is the last thing Minitest prints but for a note about skips,
    # so a tail this size holds it unless a test floods the log afterwards.
    SUMMARY_TAIL_BYTES = 64 << 10
    MAX_DECLARATION_BYTES = 4 << 20

    # How one step runs its files: the runner, the step's name, the child
    # environment, each file's deadline in seconds, and the working directory.
    Step = Data.define(:runner, :name, :environment, :deadline, :root)

    # One file's verdict: failure is nil on success, else a short reason.
    Verdict = Data.define(:path, :log, :failure)

    # About half the CPUs, or ERX_TEST_JOBS when set to a positive count.
    def jobs(environment: ENV, cpus: Etc.nprocessors)
      requested = environment[JOBS_VARIABLE]
      return [cpus / 2, 1].max if requested.nil? || requested.empty?

      unless /\A[1-9][0-9]{0,3}\z/.match?(requested) && requested.to_i <= MAX_JOBS
        raise Error, "#{JOBS_VARIABLE} must be a count from 1 to #{MAX_JOBS}"
      end

      requested.to_i
    end

    # Runs every path to a verdict, then returns the verdicts in the order of
    # paths, or reports each failed file and its log on the terminal and
    # raises Error.
    def run(paths, runner:, name:, environment:, deadline:, root:, pool_size: jobs)
      step = Step.new(runner: runner, name: name, environment: environment, deadline: deadline, root: root)
      paths = paths.map(&:to_s)
      raise Error, "#{name}: no test files" if paths.empty?
      raise Error, "#{name}: a test file is listed twice" unless paths.uniq.size == paths.size

      serial, parallel = paths.partition { |path| serial?(path) }
      verdicts = run_batch(parallel, step: step, pool_size: pool_size) +
                 run_batch(serial, step: step, pool_size: 1)
      ordered = verdicts.sort_by { |verdict| paths.index(verdict.path) }
      raise Error, "#{name}: ran #{ordered.size} of #{paths.size} test files" unless ordered.map(&:path) == paths

      failed = ordered.reject { |verdict| verdict.failure.nil? }
      return ordered if failed.empty?

      # One line each: the terminal escapes newlines inside a message.
      failed.each { |verdict| Terminal.puts(failure_line(verdict)) }
      raise Error, "#{name}: #{failed.size} of #{paths.size} test files failed (listed above)"
    end

    def failure_line(verdict)
      log = verdict.log && "; log: #{verdict.log}"
      "#{verdict.path}: #{verdict.failure}#{log}"
    end
    private_class_method :failure_line

    def serial?(path)
      File.open(path, 'rb') { |file| file.read(MAX_DECLARATION_BYTES) }.to_s.match?(SERIAL_PATTERN)
    end

    # The name a file's command and log carry: the file's stem, lower case,
    # with anything the runner's name rule refuses turned into a hyphen.
    def command_name(name, path)
      "#{name}-#{File.basename(path, '_test.rb').downcase.gsub(/[^a-z0-9_-]/, '-')}"
    end

    # A worker takes paths until the queue is empty or the batch is stopped.
    # Stopping (on an interrupt or an error in the joining thread) makes each
    # running command end through the runner's own cancel path, which kills
    # the command's process group, so no worker is ever killed mid-cleanup.
    def run_batch(paths, step:, pool_size:)
      return [] if paths.empty?

      queue = Queue.new
      paths.each { |path| queue << path }
      queue.close
      results = Queue.new
      stopped = false
      workers = Array.new([pool_size, paths.size].min) do
        Thread.new do
          while !stopped && (path = queue.pop)
            results << verdict_for(path, step, cancelled: -> { stopped })
          end
        end
      end
      begin
        workers.each(&:join)
      ensure
        stopped = true
        workers.each(&:join)
      end
      Array.new(results.size) { results.pop }
    end
    private_class_method :run_batch

    # Every outcome of one file becomes a verdict, so one file's unexpected
    # exception fails the step and names the file instead of ending its worker
    # and starving the rest of the queue. The reason keeps the exception's
    # first backtrace frame, since the step reports no backtrace.
    def verdict_for(path, step, cancelled:)
      record = step.runner.run([RbConfig.ruby, '-I', File.join(step.root, 'test/host'), path],
                               name: command_name(step.name, path), deadline: step.deadline,
                               chdir: step.root, env: step.environment, cancelled: cancelled)
      Verdict.new(path: path, log: record.fetch('log'), failure: unrun_reason(record.fetch('log')))
    rescue CommandError => error
      Verdict.new(path: path, log: error.result.fetch('log'), failure: error.result.fetch('state'))
    rescue StandardError => error
      Verdict.new(path: path, log: nil,
                  failure: "#{error.class}: #{error.message} (#{error.backtrace&.first})")
    end
    private_class_method :verdict_for

    # The last Minitest summary in the log's tail decides. A file that printed
    # none, ran nothing, skipped everything or reports failures although its
    # process exited cleanly (an at_exit handler can override Minitest's exit
    # status) did not pass.
    def unrun_reason(log)
      tail = File.open(log, 'rb') do |file|
        file.seek([file.size - SUMMARY_TAIL_BYTES, 0].max)
        file.read
      end
      match = tail.to_s.scan(SUMMARY).last
      return 'ran no tests: no Minitest summary in the log' if match.nil?

      runs, failures, errors, skips = match.map(&:to_i)
      return 'ran no tests: 0 runs' if runs.zero?
      return 'ran no tests: every test skipped' if skips >= runs
      return 'exited cleanly but the summary shows failures' if failures.positive? || errors.positive?

      nil
    end
    private_class_method :unrun_reason
  end
end
