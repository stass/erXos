# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'minitest/autorun'
require 'rbconfig'
require 'set'
require 'tmpdir'
require_relative '../../tools/lib/erx/interactive_boot'

# The pure half of `tools/erx boot` (its arguments, the accelerator it picks
# and the QEMU argument vector it plans) and the child handling of its run,
# with a Ruby child standing in for QEMU. Nothing here boots a guest.
class InteractiveBootTest < Minitest::Test
  def test_no_arguments_ask_for_one_cpu_and_this_hosts_accelerator
    assert_equal Erx::InteractiveBoot::Request.new(accel: nil, cpus: 1, jobs: Erx::InteractiveBoot::DEFAULT_JOBS),
                 Erx::InteractiveBoot.request([])
  end

  def test_options_name_the_accelerator_cpus_and_jobs
    assert_equal Erx::InteractiveBoot::Request.new(accel: 'tcg', cpus: 4, jobs: 2),
                 Erx::InteractiveBoot.request(%w[--accel tcg --cpus 4 --jobs 2])
  end

  def test_bad_arguments_are_refused_as_usage_errors
    [%w[--cpus 0], %w[--cpus 9], %w[--cpus -1], %w[--cpus two], %w[--accel kvm], %w[--accel], %w[extra],
     %w[--memory-mib 512], %w[--jobs 0], %w[--jobs 65]].each do |arguments|
      assert_raises(OptionParser::ParseError, arguments.join(' ')) { Erx::InteractiveBoot.request(arguments) }
    end
  end

  def test_the_request_leaves_the_callers_arguments_alone
    arguments = %w[--cpus 2].freeze
    Erx::InteractiveBoot.request(arguments)
    assert_equal %w[--cpus 2], arguments
  end

  def test_hvf_is_the_default_where_qemu_offers_it
    assert_equal 'hvf', Erx::InteractiveBoot.default_accel(Set['hvf', 'tcg'])
    assert_equal 'tcg', Erx::InteractiveBoot.default_accel(Set['tcg'])
    assert_equal 'tcg', Erx::InteractiveBoot.default_accel(Set[])
  end

  def test_qemu_runs_on_this_terminal_with_its_monitor_muxed_and_never_reboots
    argv = Erx::InteractiveBoot.argv(accel: 'hvf', cpus: 2, image: '/tree/build/image.boot')
    assert_equal 'qemu-system-aarch64', argv.first
    assert_equal 'mon:stdio', argv.fetch(argv.index('-serial') + 1)
    # The console is the first serial line; the second, the host link's UART, is QEMU's null device.
    assert_equal %w[mon:stdio null], argv.each_index.select { |at| argv[at] == '-serial' }.map { |at| argv[at + 1] }
    assert_includes argv, '-no-reboot'
    assert_equal '/tree/build/image.boot', argv.fetch(argv.index('-kernel') + 1)
    assert_equal '2', argv.fetch(argv.index('-smp') + 1)
    assert_equal Erx::ProductionImage::MEMORY_MIB.to_s, argv.fetch(argv.index('-m') + 1)
    refute(argv.any? { |word| word.start_with?('file:') })
  end

  def test_each_accelerator_gets_the_harness_kernel_command_line
    tcg = Erx::InteractiveBoot.argv(accel: 'tcg', cpus: 1, image: 'image.boot')
    hvf = Erx::InteractiveBoot.argv(accel: 'hvf', cpus: 1, image: 'image.boot')
    assert_equal ['-append', Erx::ProductionImage::Run::COMMAND_LINES.fetch('tcg')], tcg.last(2)
    refute_includes hvf, '-append'
  end

  def test_run_returns_the_childs_exit_status
    assert_equal 3, Erx::InteractiveBoot.run([RbConfig.ruby, '-e', 'exit 3'])
    assert_equal 0, Erx::InteractiveBoot.run([RbConfig.ruby, '-e', 'exit 0'])
  end

  def test_a_child_ended_by_a_signal_is_a_failure
    assert_equal 1, Erx::InteractiveBoot.run([RbConfig.ruby, '-e', 'Process.kill("KILL", Process.pid)'])
  end

  # An interrupt that reaches tools/erx while QEMU runs must not leave QEMU
  # running: the child writes its pid, the test interrupts the waiting run,
  # and afterwards no process has that pid.
  def test_an_interrupt_stops_the_child_before_it_propagates
    pid = interrupted_child(body: 'sleep 60', interrupts: 1)
    assert_raises(Errno::ESRCH) { Process.kill(0, pid) }
  end

  # A child that ignores SIGTERM, interrupted twice: the second interrupt
  # waits for the cleanup, which kills the child once its time is up.
  def test_a_second_interrupt_cannot_cut_the_stop_short
    pid = interrupted_child(body: 'trap("TERM") {}; sleep 60', interrupts: 2)
    assert_raises(Errno::ESRCH) { Process.kill(0, pid) }
  end

  private

  # Runs a Ruby child with body under InteractiveBoot.run, raises Interrupt
  # in this thread interrupts times once the child has written its pid,
  # checks the interrupt propagated, and returns the child's pid.
  def interrupted_child(body:, interrupts:)
    Dir.mktmpdir('erx-interactive-boot-') do |directory|
      pid_file = File.join(directory, 'pid')
      child = [RbConfig.ruby, '-e', "File.write(ARGV.fetch(0), Process.pid.to_s); #{body}", pid_file]
      waiter = Thread.new(Thread.current) do |main|
        deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 30
        sleep(0.05) until File.size?(pid_file) || Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
        sleep(0.2) # the trap, where there is one, is set right after the write
        interrupts.times do
          main.raise(Interrupt)
          sleep(0.2)
        end
      end
      begin
        assert_raises(Interrupt) { Erx::InteractiveBoot.run(child, stop_seconds: 1) }
      ensure
        waiter.join(35) || waiter.kill
      end
      pid = Integer(File.read(pid_file))
      # A regressed stop leaves the child running: the caller's assertion
      # fails, and the child still does not outlive the test.
      begin
        Process.kill('KILL', pid)
      rescue Errno::ESRCH
        nil
      end
      return pid
    end
  end
end
