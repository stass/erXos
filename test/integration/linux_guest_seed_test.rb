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
# Each boots QEMU under HVF and the seeded one waits out B's second of patience, so
# `make check` excuses this file (STANDALONE_INTEGRATION_TESTS in tools/erx). Needs
# ERX_CLANG, ERX_LLD and `tools/erx fetch --linux`; a missing one is a failure, not a skip.
class LinuxGuestSeedTest < Minitest::Test
  ROOT = File.expand_path('../..', __dir__)

  def wake_cells(seeded)
    runner = Erx::Runner.new(owner_root: ROOT, log_dir: File.join(ROOT, 'build/logs'))
    built = Erx::LinuxGuest.build(root: ROOT, runner: runner, seeded: seeded)
    report = Dir.mktmpdir('linux-guest-seed-', File.join(ROOT, 'build')) do |directory|
      Erx::LinuxGuest.boot(root: ROOT, runner: runner, built: built, benchmark: 'wake', cpus: 1,
                           directory: directory).then { |booted| File.binread(booted.fetch('serial_log')) }
    end
    lines = Erx::NativeBench.guest_lines(report)
    Erx::BenchMeasurement.boot(lines, Erx::PeerBench.asked('wake', cpus: 1, clock: 'counter'))
  end

  def cell(answer, operation)
    found = answer.fetch(:cells).find { |kept| kept.operation == operation }
    found or flunk("no #{operation} cell")
  end

  def test_a_plain_boot_measures_the_same_cpu_wake
    answer = wake_cells([])
    assert_empty answer.fetch(:refused)
    refute_nil answer.fetch(:clock)
    assert_equal 'measured', cell(answer, 'wake-same-cpu').status
  end

  def test_the_seeded_lost_wake_fails_the_same_cpu_wake
    seed = Erx::NativeBench::GUESTS.fetch('wake').seeds.find { |kept| kept.name == 'lost wake' }
    refute_nil seed, 'the native wake guest has no lost wake seed'
    wake = cell(wake_cells(seed.root_flags), 'wake-same-cpu')
    assert_equal 'failed', wake.status
    assert_equal 1, wake.counts.fetch('lost')
  end
end
