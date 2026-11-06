# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'minitest/autorun'
require 'tmpdir'
require 'optparse'
require_relative '../../tools/lib/erx/bench'
load File.expand_path('../../tools/erx', __dir__) unless defined?(Erx::CLI)

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

  ASKED = { workload: 'spawn', iterations: 10, samples: 2, flavour: 'emu' }.freeze
  SAMPLE = { 'emu_flavor' => 'emu', 'iterations' => 10, 'operations' => 10, 'workload' => 'spawn',
             'samples' => 2, 'ns_per_operation' => [1.0, 2.0], 'schedulers' => 1,
             'beam_md5' => 'a' * 32 }.freeze

  def refusal(**override)
    Erx::BenchMeasurement.refusal(SAMPLE.merge(override.transform_keys(&:to_s)), **ASKED)
  end

  def test_a_measurement_matching_what_was_asked_is_accepted
    assert_nil Erx::BenchMeasurement.refusal(SAMPLE, **ASKED)
    assert_nil Erx::BenchMeasurement.validate(SAMPLE, **ASKED)
  end

  def test_a_measurement_that_differs_from_what_was_asked_is_refused_for_that_field
    assert_match(/emu_flavor is not the requested emu/, refusal(emu_flavor: 'jit'))
    assert_match(/workload is not the requested spawn/, refusal(workload: 'ring'))
    assert_match(/iterations is not the requested 10/, refusal(iterations: 11))
    assert_match(/samples is not the requested 2/, refusal(samples: 3))
    assert_match(/schedulers is not the requested 1/, refusal(schedulers: 2))
    assert_match(/operations is not a positive integer/, refusal(operations: 0))
    assert_match(/beam_md5 is not a lowercase MD5/, refusal(beam_md5: 'ABC'))
    assert_match(/not one number per sample/, refusal(ns_per_operation: [1.0]))
    assert_match(/not positive and finite/, refusal(ns_per_operation: [Float::INFINITY, 2.0]))
    assert_match(/not positive and finite/, refusal(ns_per_operation: [0, 2.0]))
    assert_match(/not a JSON object/, Erx::BenchMeasurement.refusal([], **ASKED))
  end

  def test_validate_raises_the_refusal_as_an_error
    error = assert_raises(Erx::Error) do
      Erx::BenchMeasurement.validate(SAMPLE.merge('emu_flavor' => 'jit'), **ASKED)
    end
    assert_match(/emu_flavor/, error.message)
  end

  def test_bench_options_that_do_not_apply_are_refused
    cli = Erx::CLI
    assert_raises(OptionParser::InvalidArgument) { cli.bench(%w[g3 --accel hvf --iterations 5]) }
    assert_raises(OptionParser::InvalidArgument) { cli.bench(%w[g3 --accel hvf --samples 5]) }
    assert_raises(OptionParser::InvalidArgument) { cli.bench(%w[otp-spawn --accel hvf]) }
    assert_raises(OptionParser::InvalidArgument) { cli.bench(%w[otp-spawn --image /x]) }
    assert_raises(OptionParser::MissingArgument) { cli.bench(%w[g3]) }
  end

  ORACLE_ROOT = File.expand_path('../..', __dir__)

  # These run stock OTP's erx_otp_bench on this host at the smallest sizes, so the module
  # itself (its operations count and digest) is checked and not only the Ruby around it.
  def with_oracle_bench
    skip 'the emu oracle is not built here (make oracle-bootstrap)' unless
      File.directory?(File.join(ORACLE_ROOT, 'build/oracle/emu/install'))
    yield Erx::Bench.new(root: ORACLE_ROOT)
  end

  def test_stock_ring_counts_the_sends_of_whole_rounds
    with_oracle_bench do |bench|
      measurement = bench.run('otp-ring', iterations: 1, samples: 1).fetch('measurement')
      assert_equal 10_001, measurement.fetch('operations')
      assert_equal 1, measurement.fetch('iterations')
      assert_equal 1, measurement.fetch('schedulers')
      assert_nil Erx::BenchMeasurement.refusal(measurement, workload: 'ring', iterations: 1, samples: 1, flavour: 'emu')
    end
  end

  def test_stock_switch_counts_two_yields_to_an_iteration
    with_oracle_bench do |bench|
      measurement = bench.run('otp-switch', iterations: 3, samples: 2).fetch('measurement')
      assert_equal 6, measurement.fetch('operations')
      assert_equal 2, measurement.fetch('ns_per_operation').size
    end
  end

  def test_stock_runs_share_the_one_compiled_beam
    with_oracle_bench do |bench|
      beam = bench.compile_beam
      reports = %w[otp-spawn otp-switch].map { |name| bench.run(name, iterations: 2, samples: 1, beam: beam) }
      assert_equal [beam.sha256], reports.map { |report| report.fetch('beam_sha256') }.uniq
      assert_equal 1, reports.map { |report| report.fetch('measurement').fetch('beam_md5') }.uniq.size
      assert_equal beam.bytes, File.binread(File.join(beam.directory, 'erx_otp_bench.beam'))
    end
  end

  def test_the_footprint_of_stock_parses_and_names_the_time_unit
    with_oracle_bench do |bench|
      measurement = bench.footprint.fetch('measurement')
      assert_equal 1, measurement.fetch('schedulers')
      assert_operator measurement.fetch('native_time_unit_hz'), :>, 0
      assert_equal 'emu', measurement.fetch('emu_flavor')
    end
  end

  def test_the_load_average_is_text_from_the_host
    assert_match(/\d/, @bench.load_average)
  end
end
