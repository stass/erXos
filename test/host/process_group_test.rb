# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'minitest/autorun'
require 'tmpdir'
require 'rbconfig'
require_relative '../../tools/lib/erx/process_group'

class ProcessGroupTest < Minitest::Test
  # On macOS, signalling a process group whose only members have exited but
  # are not yet reaped fails with EPERM instead of ESRCH (a child that aborted
  # under a sanitizer leaves such a group for a moment). The group is gone.
  def test_signalling_a_group_of_exited_processes_is_not_an_error
    pid = Process.spawn(RbConfig.ruby, '-e', 'exit!', pgroup: true)
    sleep 0.3 # exited, not reaped: a zombie
    Erx::ProcessGroup.signal('TERM', pid)
  ensure
    Process.wait(pid) if pid
  end

  # Counts the group's waits, and performs each one.
  def counting_waits
    waits = []
    original = Erx::ProcessGroup.method(:sleep)
    Erx::ProcessGroup.define_singleton_method(:sleep) do |seconds|
      waits << seconds
      original.call(seconds)
    end
    waits
  end

  def teardown
    Erx::ProcessGroup.singleton_class.send(:remove_method, :sleep) if Erx::ProcessGroup.singleton_methods(false).include?(:sleep)
  end

  # Every command ends here, and a finished one has nothing left to flush: waiting out
  # the grace period would cost each short child 0.25 s.
  def test_a_finished_command_does_not_wait_out_the_grace_period
    waits = counting_waits
    pid = Process.spawn(RbConfig.ruby, '-e', 'exit!', pgroup: true)
    Process.wait(pid)
    Erx::ProcessGroup.terminate(pid)
    assert_empty waits
  end

  def test_a_member_that_ignores_term_gets_the_grace_period_and_then_a_kill
    waits = counting_waits
    Dir.mktmpdir do |directory|
      ready = File.join(directory, 'ready')
      script = %(trap "" TERM; : > "$0"; while :; do /bin/sleep 1; done)
      pid = Process.spawn('/bin/sh', '-c', script, ready, pgroup: true)
      begin
        wait_until('the member to start') { File.exist?(ready) }
        Erx::ProcessGroup.terminate(pid)
        refute_empty waits
        # terminate reaps only its child, so a killed grandchild ends a moment later.
        wait_until('the group to end') { Erx::ProcessGroup.gone?(pid) }
      ensure
        Erx::ProcessGroup.signal('KILL', pid)
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
end
