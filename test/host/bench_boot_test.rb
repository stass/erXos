# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'minitest/autorun'
require 'rbconfig'
require 'stringio'
require 'tmpdir'
require_relative '../../tools/lib/erx/bench_boot'
require_relative '../../tools/lib/erx/bench_guest_log'

class BenchBootTest < Minitest::Test
  BANNER = Erx::ProductionImage::Run::COMMAND_SHELL_BANNER
  # What a boot prints, in the order it prints it, with the console's colour codes on the banner.
  LINES = ["\e[1;32merXos\r\n", "erx: root task: build 7f96 index 9e62 entries 6\r\n",
           "Erlang/OTP 29 [erts-17.1.1] [source]\r\n", "#{BANNER}\r\n"].freeze

  def line(seconds, text) = Erx::BenchBoot::Line.new(seconds: seconds, text: text)

  def test_marks_name_the_harness_checkpoints_the_guest_log_reads
    assert_empty Erx::BenchGuestLog::BOOT_POINTS - Erx::BenchBoot::MARK_NAMES
  end

  def test_marks_take_the_first_line_of_each_kind_and_skip_one_never_printed
    lines = [line(0.01, "\e[1;32merXos\r\n"), line(0.02, "erx: root task: build a\n"),
             line(0.03, "erx: root task: build b\n"), line(0.5, "#{BANNER}\r\n")]
    assert_equal({ 'erxos-banner' => 0.01, 'root-identity' => 0.02, 'release-shell' => 0.5 },
                 Erx::BenchBoot.marks(lines))
  end

  def test_the_splitter_stamps_a_line_with_the_chunk_that_ended_it
    splitter = Erx::BenchBoot::LineSplitter.new
    assert_empty splitter.push(0.1, 'erx: root task: bui')
    assert_equal [line(0.2, "erx: root task: build x\r\n")], splitter.push(0.2, "ld x\r\nErlang/OTP 29 [e")
    assert_equal [line(0.3, "Erlang/OTP 29 [erts]\n")], splitter.push(0.3, "rts]\n")
    assert_nil splitter.tail
  end

  def test_the_unfinished_line_is_a_line_the_stop_ends
    splitter = Erx::BenchBoot::LineSplitter.new
    splitter.push(0.1, "Erlang/OTP 29 [e\r\n")
    splitter.push(0.2, BANNER)
    assert_equal 0.2, Erx::BenchBoot.marks([splitter.tail]).fetch('release-shell')
  end

  def test_the_transcript_logs_every_chunk_and_stops_at_the_last_mark
    log = StringIO.new
    transcript = Erx::BenchBoot::Transcript.new(log: log)
    transcript.add(0.1, LINES.first(3).join)
    refute_predicate transcript, :complete?
    transcript.add(0.2, LINES.last)
    assert_predicate transcript, :complete?
    assert_equal LINES.join, log.string
    assert_equal Erx::BenchBoot::MARK_NAMES, transcript.found.keys
    assert_equal [LINES[2], LINES[3]], transcript.recent.map(&:text)
  end

  def test_the_transcript_refuses_a_console_past_its_byte_limit
    transcript = Erx::BenchBoot::Transcript.new(log: StringIO.new, limit: 100)
    transcript.add(0.1, 'a' * 100)
    error = assert_raises(Erx::Error) { transcript.add(0.2, 'b') }
    assert_match(/more than 100 bytes/, error.message)
  end

  def test_spread_is_median_and_quartiles_of_sorted_values
    spread = Erx::BenchBoot.spread([0.5, 0.1, 0.3, 0.2, 0.4])
    assert_equal({ 'median' => 0.3, 'min' => 0.1, 'max' => 0.5, 'q1' => 0.2, 'q3' => 0.4, 'n' => 5 }, spread)
    assert_in_delta 0.175, Erx::BenchBoot.spread([0.1, 0.2, 0.3, 0.4]).fetch('q1'), 1e-9
    assert_raises(Erx::Error) { Erx::BenchBoot.spread([]) }
  end

  def test_summary_counts_the_runs_that_missed_a_mark
    summary = Erx::BenchBoot.summarize([{ 'release-slogan' => 1.0, 'release-shell' => 2.0 }, { 'release-shell' => 4.0 }])
    assert_equal 1, summary.fetch('release-slogan').fetch('missed')
    assert_equal 3.0, summary.fetch('release-shell').fetch('median')
    assert_equal({ 'n' => 0 }, summary.fetch('erxos-banner'))
    assert_match(/never reached/, Erx::BenchBoot.format_line('erxos-banner', summary.fetch('erxos-banner')))
  end

  def test_a_run_is_complete_only_without_a_failure_and_with_every_mark_reached
    every = Erx::BenchBoot::MARK_NAMES.to_h { |name| [name, 1.0] }
    summary = Erx::BenchBoot.summarize([every])
    assert Erx::BenchBoot.complete?(summary, nil)
    refute Erx::BenchBoot.complete?(summary, { 'boot' => 2, 'error' => 'x' })
    refute Erx::BenchBoot.complete?(Erx::BenchBoot.summarize([every.except('root-identity')]), nil)
  end

  # Boots a stand-in guest, a Ruby script, under the real deadline tool; its serial bytes and
  # standard error go to serial.log and qemu.log in directory.
  def boot(script, directory:, deadline_seconds: 20)
    Erx::BenchBoot.boot_once([RbConfig.ruby, '-e', script], deadline_seconds: deadline_seconds,
                                                            serial_log: File.join(directory, 'serial.log'),
                                                            qemu_log: File.join(directory, 'qemu.log'),
                                                            timeout_program: 'gtimeout')
  end

  # A guest that prints the boot's lines and keeps running, as QEMU would.
  def test_a_boot_stops_its_process_at_the_shell_banner
    script = "$stdout.sync = true; #{LINES.inspect}.each { |line| print line; sleep 0.05 }; sleep 60"
    Dir.mktmpdir('bench-boot-test-') do |directory|
      reached = boot(script, directory: directory)
      assert_equal Erx::BenchBoot::MARK_NAMES, reached.keys
      assert_operator reached.fetch('release-shell'), :>, reached.fetch('release-slogan')
      assert_operator reached.fetch('release-shell'), :<, 10
    end
  end

  def test_a_boot_that_never_reaches_the_shell_is_a_failure
    script = "$stdout.sync = true; print #{LINES.first.inspect}; sleep 60"
    Dir.mktmpdir('bench-boot-test-') do |directory|
      error = assert_raises(Erx::Error) { boot(script, directory: directory, deadline_seconds: 1) }
      assert_match(/did not reach release-shell/, error.message)
    end
  end

  def test_a_qemu_that_ends_at_once_is_reported_as_ended_not_as_late
    Dir.mktmpdir('bench-boot-test-') do |directory|
      error = assert_raises(Erx::Error) { boot('exit 3', directory: directory) }
      assert_match(/QEMU ended before release-shell.*qemu\.log/, error.message)
    end
  end

  def test_a_boot_writes_the_serial_bytes_and_the_standard_error_to_files
    script = "$stdout.sync = true; $stderr.puts 'qemu says hi'; #{LINES.inspect}.each { |l| print l }; sleep 60"
    Dir.mktmpdir('bench-boot-test-') do |directory|
      boot(script, directory: directory)
      assert_equal LINES.join, File.binread(File.join(directory, 'serial.log'))
      assert_equal "qemu says hi\n", File.read(File.join(directory, 'qemu.log'))
    end
  end

  def test_a_flooding_console_fails_at_the_byte_limit_and_its_process_is_ended
    Dir.mktmpdir('bench-boot-test-') do |directory|
      pid_file = File.join(directory, 'pid')
      script = "File.write(#{pid_file.inspect}, Process.pid); $stdout.sync = true; " \
               "begin; loop { print 'x' * 65_536 }; rescue Errno::EPIPE; end; sleep 60"
      error = assert_raises(Erx::Error) { boot(script, directory: directory, deadline_seconds: 30) }
      assert_match(/more than #{Erx::BenchBoot::MAX_SERIAL_BYTES} bytes/, error.message)
      assert_process_gone File.read(pid_file).to_i
    end
  end

  # An exception in the host, here an interrupt, while the guest is silent: the guest's
  # process group is still ended.
  def test_an_interrupt_during_a_boot_ends_the_process_group
    Dir.mktmpdir('bench-boot-test-') do |directory|
      pid_file = File.join(directory, 'pid')
      booting = Thread.new { boot("File.write(#{pid_file.inspect}, Process.pid); sleep 60", directory: directory) }
      booting.report_on_exception = false
      wait_for_file(pid_file)
      pid = File.read(pid_file).to_i
      booting.raise(Interrupt)
      assert_raises(Interrupt) { booting.join }
      assert_process_gone pid
    end
  end

  def wait_for_file(path)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 20
    until File.size?(path)
      flunk "#{path} was not written" if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
      sleep 0.02
    end
  end

  def assert_process_gone(pid)
    Process.kill(0, pid)
    flunk "process #{pid} is still running"
  rescue Errno::ESRCH
    pass
  ensure
    begin
      Process.kill('KILL', pid)
    rescue SystemCallError
      nil
    end
  end
end
