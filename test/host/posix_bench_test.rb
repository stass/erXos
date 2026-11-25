# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'minitest/autorun'
require_relative '../../tools/lib/erx/posix_bench'

# erXos's posix guest (docs/design-bench.md, "How erXos runs the program"): the image's
# manifest edit and machine, the line root's session types, and the forms and profiles
# the guest boots in. The boot itself is the bench session's.
class PosixBenchTest < Minitest::Test
  ROOT = File.expand_path('../..', __dir__)
  MIB = 1 << 20

  def setup
    @platform = Erx::Platform.development(ROOT)
    @source = @platform.manifest_source(ROOT)
  end

  def value(text, record, field) = Erx::Manifest::Edit.value(text, record: record, field: field)

  # The session's /tmp cap is 48 MiB, and the memory that backs it grows by as much at
  # each level that admits it; the QEMU machine gains that RAM.
  def test_manifest_raises_the_session_tmp_cap_and_the_memory_behind_it
    edited = Erx::PosixBench.manifest(@source)
    assert_equal 48 * MIB, value(edited, 'runtime_limits session', 'tmp')
    [['limits session', 'memory'], ['principal system', 'memory'], %w[machine root_memory]].each do |record, field|
      assert_equal value(@source, record, field) + (48 * MIB), value(edited, record, field), "#{record} #{field}"
    end
    assert_equal value(@source, 'runtime_limits system', 'tmp'), value(edited, 'runtime_limits system', 'tmp')
    assert_equal @platform.memory_mib + 48, Erx::PosixBench.machine(@platform).memory_mib
  end

  # The command names the program, its benchmark and the boot's CPU count, and ends in
  # the carriage return a terminal's Enter sends; the session's shell types it.
  def test_session_shell_types_the_program_with_the_boot_cpu_count
    assert_equal "erx_peer_bench posix 4\r", Erx::PosixBench.command(4)
    points = Erx::PosixBench.checkpoints([{ name: 'release-shell' }], cpus: 1)
    shell = points.find { |point| point[:name] == 'root-shell' }
    assert_equal "erx_peer_bench posix 1\r", shell.fetch(:type)
    assert_equal %w[release-shell root-shell bench-timing bench-done], points.map { |point| point[:name] }
    assert_match points.last.fetch(:pattern), "erx: bench: done\r\n"
  end

  def test_flags_build_the_erxos_branch_with_the_peer_flags_and_a_seed
    flags = Erx::PosixBench.flags(seeded: ['-DERX_PEER_SEED_NO_PROBE'])
    assert_equal '-DERX_PEER_ERXOS', flags.first
    assert_equal '-DERX_PEER_SEED_NO_PROBE', flags.last
    assert_equal Erx::PeerBench.flags, flags[1...-1]
  end

  def test_guest_boots_one_cpu_and_the_boot_count_at_the_landing_profiles_only
    guest = Erx::PosixBench::Guest.new(root: ROOT, runner: nil)
    assert_equal %w[erxos posix], [guest.system, guest.boot]
    assert_equal [1, 4], guest.forms(Erx::BenchSuite::BOOTS.fetch('posix').cpus)
    assert_equal [1], guest.forms(1)
    assert_nil guest.refusal('landing')
    assert_match(/landing profiles only/, guest.refusal('full'))
  end
end
