# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'minitest/autorun'
require 'tmpdir'
require_relative '../../tools/lib/erx/bench'

class BenchTest < Minitest::Test
  def setup
    @root = Dir.mktmpdir('erx-bench-')
    FileUtils.copy_file(File.expand_path('../../deps.lock', __dir__), File.join(@root, 'deps.lock'))
    @bench = Erx::Bench.new(root: @root)
  end

  def teardown
    FileUtils.remove_entry(@root)
  end

  def test_invalid_requests_fail_before_runtime_execution
    assert_raises(Erx::Error) { @bench.run('unknown') }
    assert_raises(Erx::Error) { @bench.run('otp-spawn', iterations: 0) }
    assert_raises(Erx::Error) { @bench.run('otp-spawn', samples: 101) }
    refute File.exist?(File.join(@root, 'build/bench'))
  end

  def test_measurement_must_match_the_requested_conditions
    sample = { 'emu_flavor' => 'emu', 'iterations' => 10, 'workload' => 'spawn',
               'samples' => 2, 'ns_per_operation' => [1.0, 2.0] }
    assert @bench.send(:validate_measurement, sample, flavour: 'emu', samples: 2,
                      iterations: 10, workload: 'spawn').nil?
    invalid = sample.merge('emu_flavor' => 'jit')
    assert_raises(Erx::Error) do
      @bench.send(:validate_measurement, invalid, flavour: 'emu', samples: 2,
                  iterations: 10, workload: 'spawn')
    end
    invalid = sample.merge('ns_per_operation' => [Float::INFINITY, 2.0])
    assert_raises(Erx::Error) do
      @bench.send(:validate_measurement, invalid, flavour: 'emu', samples: 2,
                  iterations: 10, workload: 'spawn')
    end
  end
end
