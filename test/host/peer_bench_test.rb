# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'minitest/autorun'
require_relative '../../tools/lib/erx/linux_guest'
require_relative '../../tools/lib/erx/peer_bench'

# bench/peer/erx_peer_bench.c's lines as the host reads them (docs/design-bench.md, "Other
# systems on the same Raspberry Pi 4"): test/fixtures/peer_bench/linux holds one run of each
# benchmark, as printed by the file built with PeerBench.flags: nullcall, wake and posix by Linux's
# guest under HVF at 4 CPUs (LinuxGuest.build and .boot, the serial log from the program's
# first line), the others by gcc in an arm64 Linux container with 16 CPUs. Each run's
# lines go through BenchMeasurement.boot as a native boot's do: nothing is refused, every
# cell the counterparts table names a counterpart for is measured, and every other asked
# cell is unsupported, so a change to the reader or to the
# declarations that the file does not follow shows here.
class PeerBenchTest < Minitest::Test
  FIXTURES = File.expand_path('../fixtures/peer_bench/linux', __dir__)
  CPUS = { 'nullcall' => 4, 'wake' => 4, 'vm' => 16, 'sched' => 16, 'xdomain' => 16, 'posix' => 4 }.freeze
  # The operations with no counterpart in the table, which the file reports unsupported.
  UNSUPPORTED = { 'nullcall' => [], 'vm' => %w[reserve release], 'wake' => %w[trigger-take], 'sched' => [],
                  'xdomain' => [], 'posix' => [] }.freeze

  def imported(name)
    lines = Erx::NativeBench.guest_lines(File.binread(File.join(FIXTURES, "#{name}.log")))
    Erx::BenchMeasurement.boot(lines, Erx::PeerBench.asked(name, cpus: CPUS.fetch(name), clock: 'counter'))
  end

  def test_every_run_imports_with_each_cell_measured_or_without_a_counterpart
    UNSUPPORTED.each do |name, unsupported|
      result = imported(name)
      assert_empty result[:refused], name
      refute_nil result[:clock], name
      result[:cells].each do |cell|
        want = unsupported.include?(cell.operation) ? 'unsupported' : 'measured'
        assert_equal want, cell.status, "#{name} #{cell.operation} #{cell.conditions.placement}: #{cell.reason}"
      end
    end
  end

  def test_a_native_set_run_calibrates_cpu_0_against_the_last
    pairs = imported('wake')[:clock].fetch('pairs')
    assert_equal [[0, CPUS.fetch('wake') - 1]], pairs.map { |pair| pair.fetch('cpus') }
    assert_empty imported('xdomain')[:clock].fetch('pairs')
  end

  def test_the_cross_cpu_wake_carries_its_uncertainty
    cell = imported('wake')[:cells].find { |kept| kept.operation == 'wake-cross-cpu' }
    assert_kind_of Integer, cell.detail.fetch('uncertainty')
    assert_equal 1, cell.conditions.batch
  end

  def test_the_build_flags_carry_the_declared_xdomain_parameters
    parameters = Erx::BenchSuite.benchmark('xdomain').landing.fetch('xdomain').first.parameters
    assert_includes Erx::PeerBench.flags, "-DERX_PEER_XDOMAIN_ENCODED=#{parameters.fetch('encoded')}u"
    assert_raises(Erx::Error) { Erx::PeerBench.asked('missing', cpus: 16, clock: 'counter') }
  end

  # posix takes the CPU count as its second argument, since on erXos the program cannot ask
  # for it, and calibrates CPU 0 against the last as a native-set run does.
  def test_a_posix_run_is_given_the_cpu_count_and_calibrates_the_pair
    assert_equal %w[posix 4], Erx::PeerBench.arguments('posix', cpus: 4)
    assert_equal %w[wake], Erx::PeerBench.arguments('wake', cpus: 4)
    assert_equal [[0, 3]], Erx::PeerBench.asked('posix', cpus: 4, clock: 'counter').pairs
    assert_empty Erx::PeerBench.asked('posix', cpus: 1, clock: 'counter').pairs
    assert_includes Erx::PeerBench.flags, '-DERX_BENCH_EXPENSIVE_SAMPLES=100u'
  end

  # Linux's guest boots posix with the count after the kernel's arguments, a /tmp for its
  # files, and the memory of erXos's posix machine it is set beside.
  def test_linux_boots_posix_with_its_arguments_tmp_and_memory
    root = File.expand_path('../..', __dir__)
    platform = Erx::Platform.development(root)
    posix = Erx::LinuxGuest.machine('posix', cpus: 4, platform: platform)
    assert_equal "#{Erx::LinuxGuest::COMMAND_LINE} -- posix 4", posix.fetch(:command_line)
    assert_equal Erx::PosixBench.machine(platform).memory_mib, posix.fetch(:memory_mib)
    assert_equal({ command_line: "#{Erx::LinuxGuest::COMMAND_LINE} -- wake", memory_mib: Erx::NativeBench::MEMORY_MIB },
                 Erx::LinuxGuest.machine('wake', cpus: 4, platform: platform))
    assert_includes Erx::LinuxGuest.initramfs(init: ''.b, peer: ''.b), "tmp\0"
    assert_equal 'posix', Erx::LinuxGuest::Guest.new(root: root, runner: nil, boot: 'posix').boot
    assert_equal 'native', Erx::LinuxGuest::Guest.new(root: root, runner: nil).boot
    assert_raises(Erx::Error) { Erx::LinuxGuest::Guest.new(root: root, runner: nil, boot: 'xdomain') }
  end

  # A system whose placement call is refused runs posix unpinned: the program is told so
  # after its CPU count, and the run calibrates no pair, so its CLOCK line asks for none.
  def test_an_unpinned_posix_run_is_told_so_and_calibrates_no_pair
    assert_equal %w[posix 4 unpinned], Erx::PeerBench.arguments('posix', cpus: 4, pinned: false)
    assert_equal %w[posix 4], Erx::PeerBench.arguments('posix', cpus: 4)
    assert_equal [], Erx::PeerBench.asked('posix', cpus: 4, clock: 'counter', pinned: false).pairs
    assert_equal [[0, 3]], Erx::PeerBench.asked('posix', cpus: 4, clock: 'counter').pairs
    assert_raises(Erx::Error) { Erx::PeerBench.arguments('wake', cpus: 4, pinned: false) }
    # What its record says: an unpinned posix run and an xdomain run pin nothing.
    assert_equal [true, false, false, true], [Erx::PeerBench.pins?('posix'), Erx::PeerBench.pins?('posix', pinned: false),
                                              Erx::PeerBench.pins?('xdomain'), Erx::PeerBench.pins?('wake')]
  end

  # Both builds of the file generate code from one list of flags, NativeRoot's without its target.
  def test_linux_compiles_with_the_erxos_programs_code_generation_flags
    assert_equal Erx::NativeRoot::CODE_FLAGS.grep_v(/\A--target=/), Erx::LinuxGuest::CODE_FLAGS
  end
end
