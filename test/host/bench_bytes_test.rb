# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'json'
require 'minitest/autorun'
require_relative '../../tools/lib/erx/bench'
require_relative '../../tools/lib/erx/bench_bytes'

# tools/erx bench bytes's report (Erx::BenchBytes): the guest's line found among the shell's
# echo, the medians less the loop's, and a run that printed nothing reported as incomplete,
# never as zeros.
class BenchBytesTest < Minitest::Test
  BEAM = Erx::Bench::Beam.new(directory: '/nonexistent', source: '/nonexistent', bytes: 'x', sha256: 'ab')

  def measurement(workloads)
    { 'iterations' => 10, 'samples' => 3, 'emu_flavor' => 'emu', 'workloads' => workloads }
  end

  def report(measurement)
    Erx::BenchBytes.report(host: 'h', now: Time.at(0).utc, build: {}, beam: BEAM, qemu: {}, serial: 's',
                           failure: nil, plan: Erx::BenchBytes::PLAN, measurement: measurement, load: {})
  end

  def test_measurement_is_read_from_its_line_among_the_echo
    line = JSON.generate(measurement('loop' => { 'status' => 'measured', 'ns_per_call' => [1.0] }))
    text = "1> io:format(\"BYTES ~s~n\",[...]).\r\nBYTES #{line}\r\nok\r\n".b

    assert_equal 'emu', Erx::BenchBytes.measurement(text).fetch('emu_flavor')
    assert_nil Erx::BenchBytes.measurement("1> io:format(\"BYTES ~s~n\").\r\n".b)
  end

  def test_medians_less_the_loop_and_an_unmeasured_input_is_nil
    measured = ->(values) { { 'status' => 'measured', 'ns_per_call' => values } }
    result = report(measurement('loop' => measured.call([10.0, 12.0, 11.0]),
                                'siphash20' => measured.call([60.0, 50.0, 55.0])))

    assert_equal 44.0, result.fetch('net_of_loop').fetch('siphash20')
    assert_nil result.fetch('net_of_loop').fetch('csum_iolist')
    assert result.fetch('complete')
  end

  def test_a_run_that_printed_nothing_is_incomplete_not_zero
    result = report(nil)

    refute result.fetch('complete')
    assert_empty result.fetch('net_of_loop')
    assert_empty result.fetch('median_ns_per_call')
  end
end
