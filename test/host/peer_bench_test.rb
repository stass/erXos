# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'minitest/autorun'
require_relative '../../tools/lib/erx/peer_bench'

# bench/peer/erx_peer_bench.c's lines as the host reads them (docs/design-bench.md, "Other
# systems on the same Raspberry Pi 4"): test/fixtures/peer_bench/linux holds one run of each
# benchmark, as printed by the file built with PeerBench.flags by gcc on Linux on arm64,
# with 16 CPUs. Each run's lines go through BenchMeasurement.boot as a native boot's do:
# nothing is refused, every cell the counterparts table names a counterpart for is
# measured, and every other asked cell is unsupported, so a change to the reader or to the
# declarations that the file does not follow shows here.
class PeerBenchTest < Minitest::Test
  FIXTURES = File.expand_path('../fixtures/peer_bench/linux', __dir__)
  CPUS = 16
  # The operations with no counterpart in the table, which the file reports unsupported.
  UNSUPPORTED = { 'nullcall' => %w[root-same-space], 'vm' => %w[reserve release],
                  'wake' => %w[wake-same-cpu trigger-take], 'sched' => [], 'xdomain' => [] }.freeze

  def imported(name)
    lines = Erx::NativeBench.guest_lines(File.binread(File.join(FIXTURES, "#{name}.log")))
    Erx::BenchMeasurement.boot(lines, Erx::PeerBench.asked(name, cpus: CPUS, clock: 'counter'))
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
    assert_equal [[0, CPUS - 1]], pairs.map { |pair| pair.fetch('cpus') }
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
    assert_raises(Erx::Error) { Erx::PeerBench.asked('missing', cpus: CPUS, clock: 'counter') }
  end
end
