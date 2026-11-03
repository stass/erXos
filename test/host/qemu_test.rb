# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'minitest/autorun'
require 'tmpdir'
require_relative '../../tools/lib/erx/qemu'

class InterruptingQemuRunner
  def run(*_arguments, **_options)
    raise Interrupt, 'fixture interruption'
  end
end

class QemuTest < Minitest::Test
  def setup
    @directory = Dir.mktmpdir('erx-qemu-')
    @serial = File.join(@directory, 'serial.log')
  end

  def teardown
    FileUtils.remove_entry(@directory)
  end

  def checkpoints
    [{ name: 'first', pattern: /^first\r?\n/n, seconds: 2 },
     { name: 'second', pattern: /^second\r?\n/n, seconds: 3 }]
  end

  def test_machine_and_accelerator_contract
    tcg = Erx::QemuPlan.argv(accel: 'tcg', image: 'image', serial: 'serial')
    hvf = Erx::QemuPlan.argv(accel: 'hvf', image: 'image', serial: 'serial')
    assert_includes tcg, 'virt-11.1,gic-version=3,msi=gicv2m'
    assert_includes hvf, 'virt-11.1,gic-version=3'
    assert_includes hvf, 'host'
    assert_includes tcg, '-no-reboot'
    assert_equal 'none', tcg.fetch(tcg.index('-nic') + 1)
    assert_equal 'none', tcg.fetch(tcg.index('-monitor') + 1)
  end

  def test_invalid_guest_configuration_is_refused
    assert_raises(Erx::Error) do
      Erx::QemuPlan.argv(accel: 'unknown', image: 'image', serial: 'serial')
    end
    assert_raises(Erx::Error) do
      Erx::QemuPlan.argv(accel: 'tcg', image: 'image', serial: 'serial', cpus: 0)
    end
  end

  def test_split_lines_match_once_in_order
    transcript = Erx::Transcript.new(checkpoints: checkpoints)
    File.write(@serial, 'fir')
    refute transcript.consume(@serial, elapsed: 0.1)
    File.open(@serial, 'a') { |file| file.write("st\r\nsecond\n") }
    assert transcript.consume(@serial, elapsed: 0.2)
    assert_equal %w[first second], transcript.observed.map { |entry| entry.fetch('name') }
    assert transcript.consume(@serial, elapsed: 0.3)
    assert_equal 2, transcript.observed.size
  end

  def test_out_of_order_line_does_not_satisfy_later_checkpoint
    transcript = Erx::Transcript.new(checkpoints: checkpoints)
    File.write(@serial, "second\nfirst\n")
    refute transcript.consume(@serial, elapsed: 0.1)
    assert_equal ['first'], transcript.observed.map { |entry| entry.fetch('name') }
    error = assert_raises(Erx::Error) { transcript.consume(@serial, elapsed: 3.2) }
    assert_match(/second/, error.message)
  end

  def test_missing_and_overlong_serial_are_failures
    transcript = Erx::Transcript.new(checkpoints: checkpoints)
    assert_raises(Erx::Error) { transcript.consume(@serial, elapsed: 2) }
    transcript = Erx::Transcript.new(checkpoints: checkpoints)
    File.write(@serial, 'x' * (Erx::Transcript::MAX_LINE_BYTES + 1))
    transcript.consume(@serial, elapsed: 0.1)
    assert_raises(Erx::Error) { transcript.consume(@serial, elapsed: 0.2) }
  end

  def fake_guest(output:, version_delay: 0, guest_delay: 0)
    path = File.join(@directory, 'fake-qemu')
    source = <<~RUBY
      #!/usr/bin/env ruby
      # frozen_string_literal: true
      if ARGV.include?('--version')
        sleep #{version_delay}
        puts 'QEMU emulator version 11.1.3 (fixture)'
        exit 0
      end
      serial = ARGV.fetch(ARGV.index('-serial') + 1).delete_prefix('file:')
      sleep #{guest_delay}
      File.binwrite(serial, #{output.dump})
    RUBY
    File.write(path, source)
    File.chmod(0o700, path)
    path
  end

  def image
    path = File.join(@directory, 'image.elf')
    File.write(path, 'fixture image')
    path
  end

  def test_successful_early_exit_drains_complete_serial_backlog
    output = "ordinary line\n" * 6000 + "done\n"
    guest = fake_guest(output: output)
    qemu = Erx::Qemu.new(root: @directory, program: guest)
    report = qemu.run(accel: 'tcg', image: image,
                      checkpoints: [{ name: 'done', pattern: /^done\n/n, seconds: 2 }])
    assert_equal 'passed', report.fetch('state')
  end

  def test_version_probe_time_does_not_consume_guest_deadline
    guest = fake_guest(output: "done\n", version_delay: 1.1)
    qemu = Erx::Qemu.new(root: @directory, program: guest)
    report = qemu.run(accel: 'tcg', image: image,
                      checkpoints: [{ name: 'done', pattern: /^done\n/n, seconds: 1 }])
    assert_equal 'passed', report.fetch('state')
  end

  def test_checkpoint_expiry_is_reported_as_timeout
    guest = fake_guest(output: '', guest_delay: 2)
    qemu = Erx::Qemu.new(root: @directory, program: guest)
    assert_raises(Erx::Error) do
      qemu.run(accel: 'tcg', image: image,
               checkpoints: [{ name: 'done', pattern: /^done\n/n, seconds: 1 }])
    end
    path = Dir.glob(File.join(@directory, 'build/qemu/*/report.json')).fetch(0)
    assert_equal 'timed_out', JSON.parse(File.read(path)).fetch('state')
  end

  def test_interruption_does_not_leave_a_running_guest_report
    qemu = Erx::Qemu.new(root: @directory, runner: InterruptingQemuRunner.new)
    assert_raises(Interrupt) { qemu.run(accel: 'tcg', image: image) }
    path = Dir.glob(File.join(@directory, 'build/qemu/*/report.json')).fetch(0)
    assert_equal 'cancelled', JSON.parse(File.read(path)).fetch('state')
  end

  def test_linked_qemu_output_branch_does_not_receive_a_guest_directory
    Dir.mktmpdir do |outside|
      FileUtils.mkdir_p(File.join(@directory, 'build'))
      File.symlink(outside, File.join(@directory, 'build/qemu'))
      qemu = Erx::Qemu.new(root: @directory, runner: InterruptingQemuRunner.new)
      begin
        qemu.run(accel: 'tcg', image: image)
      rescue Erx::Error, Interrupt
        # An invalid output branch is refused before creating guest files.
      end
      assert_empty Dir.children(outside)
    end
  end

  def test_late_checkpoint_cannot_restart_its_deadline
    transcript = Erx::Transcript.new(checkpoints: checkpoints)
    File.write(@serial, "first\nsecond\n")
    assert_raises(Erx::Error) { transcript.consume(@serial, elapsed: 3) }
  end

  def boot_transcript(available:)
    "L4 Bootstrapper\r\n  RAM: 0000000040000000 - 000000005fffffff: 512.0 MiB\r\n" \
      "  Total RAM: 512.0 MiB; available for Bootstrap/Sigma0/Kernel: #{available}\r\n" \
      "Welcome to the L4Re Microkernel!\r\ndevelopment build: trusted code only\r\n"
  end

  def test_boot_with_consistent_bootstrap_memory_passes
    qemu = Erx::Qemu.new(root: @directory, program: fake_guest(output: boot_transcript(available: '512.0 MiB')))
    report = qemu.run(accel: 'tcg', image: image)
    assert_equal %w[bootstrap-memory fiasco-banner development-warning],
                 report.fetch('checkpoints').map { |entry| entry.fetch('name') }
    assert_equal 'passed', report.fetch('state')
  end

  def test_boot_summary_must_match_guest_ram
    qemu = Erx::Qemu.new(root: @directory, program: fake_guest(output: boot_transcript(available: '512.0 MiB')))
    error = assert_raises(Erx::Error) { qemu.run(accel: 'tcg', image: image, memory_mib: 1024) }
    assert_match(/expected '.*Kernel: 1024\.0 MiB'/, error.message)
  end

  def test_boot_reporting_more_available_than_total_memory_fails
    qemu = Erx::Qemu.new(root: @directory, program: fake_guest(output: boot_transcript(available: '16.0 EiB')))
    error = assert_raises(Erx::Error) { qemu.run(accel: 'tcg', image: image) }
    assert_match(/Kernel: 16\.0 EiB/, error.message)
    path = Dir.glob(File.join(@directory, 'build/qemu/*/report.json')).fetch(0)
    report = JSON.parse(File.read(path))
    assert_equal 'failed', report.fetch('state')
    assert_empty report.fetch('checkpoints')
  end

  def test_checkpoint_verifier_must_be_callable
    point = { name: 'first', pattern: /^first\n/n, seconds: 1, verify: 'not callable' }
    assert_raises(Erx::Error) { Erx::Transcript.new(checkpoints: [point]) }
  end

  def test_malformed_checkpoint_is_a_domain_error
    assert_raises(Erx::Error) { Erx::Transcript.new(checkpoints: [nil]) }
  end
end
