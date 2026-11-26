# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'minitest/autorun'
require 'tmpdir'
require_relative '../../tools/lib/erx/linux_guest'
require_relative '../../tools/lib/erx/runner'

# Linux's guest's row of docs/design-bench.md's verification table: a one-CPU boot of the
# guest gives measured cells through BenchMeasurement and a CLOCK line, and erx_peer_bench
# built with the native bench root's seeded lost wake makes wake-same-cpu come back
# failed with one lost wake, which only the binary in that initramfs can have produced.
# The plain boot also ends long before /init's deadline, so /init woke on SIGCHLD. The
# posix table's seeded faults that Linux can show (docs/design-bench.md, "Their tests")
# each fail their cell in a one-CPU posix boot; the probe and CPU-count seeds need erXos.
# Each boots QEMU under HVF and the seeded one waits out B's second of patience, so
# `make check` excuses this file (STANDALONE_INTEGRATION_TESTS in tools/erx). Needs
# ERX_CLANG, ERX_LLD and `tools/erx fetch --linux`; a missing one is a failure, not a skip.
class LinuxGuestSeedTest < Minitest::Test
  ROOT = File.expand_path('../..', __dir__)

  # The cells of a one-CPU boot of benchmark, and how long the boot took.
  def peer_boot(benchmark, seeded)
    runner = Erx::Runner.new(owner_root: ROOT, log_dir: File.join(ROOT, 'build/logs'))
    built = Erx::LinuxGuest.build(root: ROOT, runner: runner, accel: 'hvf', seeded: seeded)
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    report = Dir.mktmpdir('linux-guest-seed-', File.join(ROOT, 'build')) do |directory|
      Erx::LinuxGuest.boot(root: ROOT, runner: runner, built: built, benchmark: benchmark, cpus: 1,
                           platform: Erx::Platform.development(ROOT), directory: directory)
                .then { |booted| File.binread(booted.fetch('serial_log')) }
    end
    lines = Erx::NativeBench.guest_lines(report)
    [Erx::BenchMeasurement.boot(lines, Erx::PeerBench.asked(benchmark, cpus: 1, clock: 'counter')),
     Process.clock_gettime(Process::CLOCK_MONOTONIC) - started]
  end

  def cell(answer, operation)
    found = answer.fetch(:cells).find { |kept| kept.operation == operation }
    found or flunk("no #{operation} cell")
  end

  def test_a_plain_boot_measures_the_same_cpu_wake
    answer, seconds = peer_boot('wake', [])
    assert_empty answer.fetch(:refused)
    refute_nil answer.fetch(:clock)
    assert_equal 'measured', cell(answer, 'wake-same-cpu').status
    # /init woke on the program's end and powered off, long before its deadline.
    assert_operator seconds, :<, Erx::LinuxGuest::DEADLINE_SECONDS / 2
  end

  def test_the_seeded_lost_wake_fails_the_same_cpu_wake
    seed = Erx::NativeBench::GUESTS.fetch('wake').seeds.find { |kept| kept.name == 'lost wake' }
    refute_nil seed, 'the native wake guest has no lost wake seed'
    wake = cell(peer_boot('wake', seed.root_flags).first, 'wake-same-cpu')
    assert_equal 'failed', wake.status
    assert_equal 1, wake.counts.fetch('lost')
  end

  # Each seed of the posix program and the operation whose cells it must fail: a close
  # skipped in a hundred, a munmap that does nothing, a peer flipping a byte in a hundred
  # replies, and a 0.5 ms sleep for the 1 ms asked; each fails the operation's same-CPU cells.
  POSIX_SEEDS = { 'LEAKED_CLOSE' => 'open', 'NOOP_MUNMAP' => 'munmap', 'FLIPPED_REPLY' => 'pipe-rtt',
                  'SHORT_SLEEP' => 'nanosleep' }.freeze

  # One test method per seed, named for it: test_the_seeded_leaked_close_fails_its_cells
  # and so on.
  POSIX_SEEDS.each do |seed, operation|
    define_method("test_the_seeded_#{seed.downcase}_fails_its_cells") do
      answer = peer_boot('posix', ["-DERX_PEER_SEED_#{seed}"]).first
      assert_empty answer.fetch(:refused)
      # A one-CPU boot reports its cross-CPU cells unsupported, whatever the seed.
      cells = answer.fetch(:cells).select { |kept| kept.operation == operation && kept.conditions.placement == 'same-cpu' }
      refute_empty cells, "no #{operation} cell"
      cells.each { |kept| assert_equal 'failed', kept.status, "#{operation} #{kept.conditions.parameters}" }
    end
  end
end
