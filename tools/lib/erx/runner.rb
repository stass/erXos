# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'fileutils'
require 'json'
require 'time'
require_relative 'error'
require_relative 'output_directory'

module Erx
  # All child output stays in logs. Diagnostics quote paths through Terminal.
  module Terminal
    def self.escape(value)
      value.to_s.dup.force_encoding(Encoding::UTF_8).scrub
           .each_codepoint.map do |point|
        if point.between?(0x20, 0x7e)
          point.chr
        else
          format('\\u{%x}', point)
        end
      end.join
    end

    def self.puts(value)
      $stderr.puts(escape(value))
    end
  end

  class CommandError < Error
    attr_reader :result

    def initialize(result)
      @result = result
      super("command #{result.fetch('state')}; log: #{result.fetch('log')}")
    end
  end

  class Runner
    POLL_SECONDS = 0.05
    PROGRESS_SECONDS = 30

    def initialize(owner_root:, log_dir:, timeout_program: 'gtimeout')
      @log_dir = OutputDirectory.prepare(root: owner_root, path: log_dir)
      @timeout_program = timeout_program
    end

    # Success predicates are for a persistent guest whose transcript is done.
    # They receive only a log path and must never print its untrusted contents.
    # output_limit is for read-only tools: the child file-size limit also caps
    # any other regular file they write, and disables their core dumps.
    def run(argv, name:, deadline:, chdir: Dir.pwd, env: {}, success: nil, cancelled: nil, output_limit: nil)
      validate(argv, name: name, deadline: deadline)
      unless output_limit.nil? || (output_limit.is_a?(Integer) && output_limit.between?(1, 1 << 40))
        raise Error, 'output limit must be a positive byte count at most 1 TiB'
      end
      file_limit = [output_limit, *Process.getrlimit(Process::RLIMIT_FSIZE)].min if output_limit
      record = reserve_record(name, argv: argv, deadline: deadline)
      record['output_limit_bytes'] = file_limit if output_limit
      started = monotonic
      pid = nil
      status = nil
      next_progress = started + PROGRESS_SECONDS

      begin
        File.open(record.fetch('log'), 'wb') do |log|
          spawn_options = { chdir: chdir, in: File::NULL, out: log, err: log,
                            pgroup: true, close_others: true }
          if output_limit
            spawn_options.merge!(rlimit_fsize: [file_limit, file_limit], rlimit_core: [0, 0])
          end
          pid = Process.spawn(env, @timeout_program, '-k', '10',
                              deadline.to_s, *argv, **spawn_options)
          record['pid'] = pid
          save(record)
          loop do
            waited = Process.waitpid2(pid, Process::WNOHANG)
            if waited
              status = waited.last
              record['state'] = classify(status, elapsed: monotonic - started, deadline: deadline)
              break
            end
            if success && success.call(record.fetch('log'))
              record['state'] = 'succeeded'
              break
            end
            if cancelled && cancelled.call
              record['state'] = 'cancelled'
              break
            end
            if monotonic >= next_progress
              progress(record, monotonic - started)
              next_progress += PROGRESS_SECONDS
            end
            sleep(POLL_SECONDS)
          end
        end
      rescue Errno::ENOENT => error
        record['state'] = 'setup_error'
        raise Error, "missing tool or working directory: #{error.message}"
      ensure
        original_error = $!
        begin
          record['state'] = 'cancelled' if record['state'] == 'running'
          terminate_group(pid) if pid
          record['elapsed_seconds'] = monotonic - started
          record['exit_status'] = status&.exitstatus
          record['signal'] = status&.termsig
          save(record)
        rescue StandardError => cleanup_error
          # A cleanup failure must not hide the command's original failure.
          raise Error, "command cleanup failed: #{cleanup_error.message}" unless original_error
          Terminal.puts("command cleanup failed: #{cleanup_error.message}")
        end
      end

      raise CommandError, record unless record['state'] == 'succeeded'

      record
    end

    private

    def validate(argv, name:, deadline:)
      unless argv.is_a?(Array) && !argv.empty? &&
             argv.all? { |argument| argument.is_a?(String) && !argument.include?("\0") }
        raise Error, 'command must be a nonempty string argument vector'
      end
      raise Error, 'invalid command name' unless /\A[a-z0-9][a-z0-9_-]*\z/.match?(name)
      unless deadline.is_a?(Integer) && deadline.positive? && deadline <= 86_400
        raise Error, 'deadline must be between 1 and 86400 seconds'
      end
    end

    def reserve_record(name, argv:, deadline:)
      # Exclusive creation gives concurrent invocations distinct log names.
      loop do
        stem = File.join(@log_dir, "#{name}-#{Process.pid}-#{Random.bytes(8).unpack1('H*')}")
        begin
          File.open("#{stem}.log", File::WRONLY | File::CREAT | File::EXCL, 0o600) {}
          return { 'argv' => argv.map { |argument| argument.dup.freeze }.freeze,
                   'started_at' => Time.now.utc.iso8601,
                   'deadline_seconds' => deadline, 'state' => 'running',
                   'log' => "#{stem}.log", 'report' => "#{stem}.json" }
        rescue Errno::EEXIST
          next
        end
      end
    end

    def classify(status, elapsed:, deadline:)
      return 'succeeded' if status.success?
      return 'timed_out' if status.exitstatus == 124 && elapsed >= deadline
      return 'timed_out' if status.exitstatus == 137 && elapsed >= deadline + 10

      'failed'
    end

    def save(record)
      path = record.fetch('report')
      temporary = "#{path}.tmp"
      File.open(temporary, 'w', 0o600) { |file| file.write(JSON.pretty_generate(record) + "\n") }
      File.rename(temporary, path)
    end

    def progress(record, age)
      Terminal.puts("running #{record.fetch('argv').first}: age #{age.round}s, " \
                    "deadline #{record.fetch('deadline_seconds')}s; #{record.fetch('log')}")
      # Read once to establish log progress without rendering guest bytes.
      record['log_bytes'] = File.size(record.fetch('log'))
      save(record)
    end

    def monotonic
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end

    def terminate_group(pid)
      signal_group('TERM', pid)
      # Reap only our direct child. Descendants are killed by their group id.
      # A bounded grace period lets log writers flush before SIGKILL, and it ends
      # as soon as no member is left to flush.
      stop_at = monotonic + 0.25
      loop do
        begin
          Process.waitpid(pid, Process::WNOHANG)
        rescue Errno::ECHILD
          # The main loop may already have reaped it.
        end
        break if group_gone?(pid) || monotonic >= stop_at
        sleep(POLL_SECONDS)
      end
      signal_group('KILL', pid)
      begin
        Process.waitpid(pid)
      rescue Errno::ECHILD
        nil
      end
    end

    # A group with no live member is gone. macOS reports a group whose members
    # have all exited but are not yet reaped as EPERM, not ESRCH. The group is
    # our own child's; a member that changed user could not be signalled by
    # this runner in any case.
    def signal_group(signal, pid)
      Process.kill(signal, -pid)
    rescue Errno::ESRCH, Errno::EPERM
      nil
    end

    # Whether no member can still flush or be signalled, by signal_group's reading of
    # the errors. Linux counts an unreaped child as a member, so the caller reaps first.
    def group_gone?(pid)
      Process.kill(0, -pid)
      false
    rescue Errno::ESRCH, Errno::EPERM
      true
    end
  end
end
