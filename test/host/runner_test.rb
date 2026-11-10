# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'minitest/autorun'
require 'tmpdir'
require 'rbconfig'
require_relative '../../tools/lib/erx/runner'

class RunnerTest < Minitest::Test
  def test_log_creation_does_not_follow_a_linked_build_branch
    Dir.mktmpdir do |temporary|
      project = File.join(temporary, 'project')
      outside = File.join(temporary, 'outside')
      FileUtils.mkdir_p([project, outside])
      File.write(File.join(outside, 'sentinel'), 'unchanged')
      File.symlink(outside, File.join(project, 'build'))
      begin
        Erx::Runner.new(owner_root: project, log_dir: File.join(project, 'build/logs'))
      rescue Erx::Error
        # Refusal must happen before any write through the linked branch.
      end
      assert_equal ['sentinel'], Dir.children(outside)
    end
  end

  def setup
    @directory = Dir.mktmpdir('erx-runner-')
    @runner = Erx::Runner.new(owner_root: @directory, log_dir: @directory)
  end

  def teardown
    FileUtils.remove_entry(@directory)
  end

  def ruby(source, **options)
    @runner.run([RbConfig.ruby, '-e', source], name: 'fixture',
                deadline: 3, **options)
  end

  def test_closed_stdin_and_preserved_arguments
    result = ruby('abort unless STDIN.read.empty?; print ARGV.inspect',
                  env: { 'ERX_TEST' => 'safe' })
    assert_equal 'succeeded', result.fetch('state')
    assert_equal '[]', File.read(result.fetch('log'))
    assert_equal 0o600, File.stat(result.fetch('log')).mode & 0o777
  end

  def test_no_shell_interpretation
    argument = '$(touch SHOULD_NOT_EXIST); `false`'
    result = @runner.run([RbConfig.ruby, '-e', 'print ARGV.fetch(0)', argument],
                         name: 'literal', deadline: 3, chdir: @directory)
    assert_equal argument, File.read(result.fetch('log'))
    refute File.exist?(File.join(@directory, 'SHOULD_NOT_EXIST'))
  end

  def test_failure_retains_evidence
    error = assert_raises(Erx::CommandError) { ruby('warn "failed"; exit 7') }
    assert_equal 7, error.result.fetch('exit_status')
    assert_equal 'failed', error.result.fetch('state')
    report = JSON.parse(File.read(error.result.fetch('report')))
    assert_equal error.result, report
  end

  def test_output_limit_is_enforced_by_the_child_before_oversized_writes
    error = assert_raises(Erx::CommandError) do
      ruby('STDOUT.sync = true; 100.times { STDOUT.write("x" * 1024) }',
            output_limit: 4096, chdir: @directory)
    end
    assert_equal 'failed', error.result.fetch('state')
    assert_operator File.size(error.result.fetch('log')), :<=, 4096
    assert_equal 4096, JSON.parse(File.read(error.result.fetch('report'))).fetch('output_limit_bytes')
    assert_empty Dir.glob(File.join(@directory, 'core*'))
  end

  def test_output_limited_commands_cannot_create_core_files
    result = ruby('print Process.getrlimit(Process::RLIMIT_CORE).inspect', output_limit: 4096)
    assert_equal '[0, 0]', File.read(result.fetch('log'))
  end

  def test_output_limit_does_not_raise_an_inherited_file_size_limit
    source = <<~RUBY
      Process.setrlimit(Process::RLIMIT_FSIZE, 8192, 8192)
      require #{File.expand_path('../../tools/lib/erx/runner', __dir__).dump}
      runner = Erx::Runner.new(owner_root: #{@directory.dump}, log_dir: #{File.join(@directory, 'nested').dump})
      begin
        runner.run([#{RbConfig.ruby.dump}, '-e', 'STDOUT.sync=true; 100.times { STDOUT.write("x" * 1024) }'],
                   name: 'inherited-limit', deadline: 2, output_limit: 65536)
      rescue Erx::CommandError => error
        print error.result.fetch('output_limit_bytes')
      end
    RUBY
    result = ruby(source, chdir: @directory)
    assert_equal '8192', File.read(result.fetch('log'))
  end

  def test_timeout_exit_code_without_deadline_is_failure
    error = assert_raises(Erx::CommandError) { ruby('exit 124') }
    assert_equal 'failed', error.result.fetch('state')
  end

  def test_timeout_is_an_error
    error = assert_raises(Erx::CommandError) do
      @runner.run([RbConfig.ruby, '-e', 'sleep 20'], name: 'timeout', deadline: 1)
    end
    assert_equal 'timed_out', error.result.fetch('state')
    # Killed at its deadline, not run to its end: short of the child's 20 s, not a speed bound.
    assert_operator error.result.fetch('elapsed_seconds'), :<, 15
  end

  def test_success_predicate_stops_guest
    result = ruby('STDOUT.sync = true; puts "banner"; sleep 20',
                  success: ->(path) { File.read(path).include?("banner\n") })
    assert_equal 'succeeded', result.fetch('state')
    assert_operator result.fetch('elapsed_seconds'), :<, 3
  end

  def test_descendant_is_killed_after_parent_exits
    marker = File.join(@directory, 'survivor')
    source = "fork { trap('TERM') {}; sleep 0.7; File.write(ARGV[0], 'alive') }; exit! 0"
    @runner.run([RbConfig.ruby, '-e', source, marker], name: 'descendant', deadline: 3)
    sleep 0.8
    refute File.exist?(marker), 'child survived completion of its command'
  end

  # On macOS, signalling a process group whose only members have exited but
  # are not yet reaped fails with EPERM instead of ESRCH (a child that aborted
  # under a sanitizer leaves such a group for a moment). The group is gone.
  def test_signalling_a_group_of_exited_processes_is_not_an_error
    pid = Process.spawn(RbConfig.ruby, '-e', 'exit!', pgroup: true)
    sleep 0.3 # exited, not reaped: a zombie
    @runner.send(:signal_group, 'TERM', pid)
  ensure
    Process.wait(pid) if pid
  end

  # Counts the runner's waits, and performs each one.
  def counting_waits(runner)
    waits = []
    runner.define_singleton_method(:sleep) do |seconds|
      waits << seconds
      Kernel.sleep(seconds)
    end
    waits
  end

  # Every command ends here, and a finished one has nothing left to flush: waiting out
  # the grace period would cost each short child 0.25 s.
  def test_a_finished_command_does_not_wait_out_the_grace_period
    waits = counting_waits(@runner)
    pid = Process.spawn(RbConfig.ruby, '-e', 'exit!', pgroup: true)
    Process.wait(pid)
    @runner.send(:terminate_group, pid)
    assert_empty waits
  end

  def test_a_member_that_ignores_term_gets_the_grace_period_and_then_a_kill
    waits = counting_waits(@runner)
    Dir.mktmpdir do |directory|
      ready = File.join(directory, 'ready')
      script = %(trap "" TERM; : > "$0"; while :; do /bin/sleep 1; done)
      pid = Process.spawn('/bin/sh', '-c', script, ready, pgroup: true)
      begin
        wait_until('the member to start') { File.exist?(ready) }
        @runner.send(:terminate_group, pid)
        refute_empty waits
        # terminate_group reaps only its child, so a killed grandchild ends a moment later.
        wait_until('the group to end') { @runner.send(:group_gone?, pid) }
      ensure
        @runner.send(:signal_group, 'KILL', pid)
      end
    end
  end

  def wait_until(what)
    stop_at = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 30
    until yield
      flunk("timed out waiting for #{what}") if Process.clock_gettime(Process::CLOCK_MONOTONIC) > stop_at
      Kernel.sleep(0.01)
    end
  end

  def test_callback_failure_cleans_up
    assert_raises(RuntimeError) do
      ruby('sleep 20', success: ->(_path) { raise 'fixture failure' })
    end
    report = JSON.parse(File.read(Dir.glob(File.join(@directory, '*.json')).fetch(0)))
    assert_equal 'cancelled', report.fetch('state')
  end

  def test_missing_tool_has_diagnostic
    runner = Erx::Runner.new(owner_root: @directory, log_dir: @directory, timeout_program: '/nonexistent/gtimeout')
    error = assert_raises(Erx::Error) do
      runner.run(['true'], name: 'missing', deadline: 1)
    end
    assert_match(/missing tool/, error.message)
  end

  def test_invalid_deadline_and_name
    assert_raises(Erx::Error) { ruby('exit', deadline: 0) }
    assert_raises(Erx::Error) { ruby('exit', name: '../escape') }
  end

  def test_terminal_escapes_controls_and_unicode
    assert_equal 'safe\\u{1b}\\u{a}\\u{202e}\\u{fffd}',
                 Erx::Terminal.escape("safe\e\n\u202e\xff".b)
  end
end
