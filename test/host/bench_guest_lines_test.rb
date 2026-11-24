# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true
# erx-gate: sanitizers

require 'minitest/autorun'
require 'open3'
require 'tmpdir'
require 'fileutils'
require_relative '../../tools/fuzz/bench_line'

# The guest library's BENCH and CLOCK lines (test/guest/bench/bench_line.c, docs/design-bench.md,
# "A benchmark") as the host reads them: a fast cell, a periodic partial cell and a two-pair
# calibration, printed by test/fixtures/bench_cores_driver.c, each pass the one validator,
# and a line that does not fit its buffer is not written at all.
class BenchGuestLinesTest < Minitest::Test
  ROOT = File.expand_path('../..', __dir__)
  SOURCES = %w[test/guest/bench/bench_hist.c test/guest/bench/bench_periodic.c test/guest/bench/bench_clock.c
               test/guest/bench/bench_line.c test/guest/bench/bench_window.c
               test/fixtures/bench_cores_driver.c].freeze

  def guest_lines
    Dir.mktmpdir('erx-bench-lines-') do |directory|
      program = File.join(directory, 'driver')
      sanitizers = ENV.fetch('ERX_SANITIZERS', '').split(',').reject(&:empty?)
      flags = sanitizers.empty? ? [] : ["-fsanitize=#{sanitizers.join(',')}", '-fno-omit-frame-pointer']
      log, built = Open3.capture2e(ENV.fetch('ERX_CLANG', 'clang'), '-std=c17', '-Wall', '-Wextra', '-Werror', '-pedantic',
                                   '-O1', '-g', '-pthread', *flags, '-I', ROOT, '-I', File.join(ROOT, 'test/guest/bench'),
                                   *SOURCES.map { |source| File.join(ROOT, source) }, '-o', program, stdin_data: '')
      assert built.success?, log
      output, ran = Open3.capture2e(program, 'lines', stdin_data: '')
      assert ran.success?, output
      output.lines.map(&:chomp)
    end
  end

  def test_the_guests_lines_pass_the_hosts_validator
    fast, periodic, costly, clock, boundary, window = guest_lines
    cell = Erx::BenchMeasurement.cell(fast, Erx::BenchLineFuzz::ASKED)
    assert_equal [40, 1000, 1199], cell.summary.values_at('samples', 'min', 'max')
    assert_equal({ 'threads' => 2, 'mode' => 'spin' }, cell.conditions.parameters)
    late = Erx::BenchMeasurement.cell(periodic, Erx::BenchLineFuzz::ASKED)
    assert_equal ['partial', 'cut short', 32], [late.status, late.reason, late.summary.fetch('samples')]
    expensive = Erx::BenchMeasurement.cell(costly, Erx::BenchLineFuzz::ASKED)
    assert_equal [20, 20], [expensive.summary.fetch('samples'), expensive.detail.fetch('raw').size]
    calibration = Erx::BenchMeasurement.clock(clock)
    assert_in_delta 27.778, calibration.fetch('cycles_per_tick'), 1e-9
    assert_equal [[-40, 12], [-35, 15], nil, [-(1 << 63), (1 << 63) - 1]],
                 calibration.fetch('pairs').flat_map { |pair| pair.values_at('before', 'after') }
    assert_equal 'boundary ok', boundary
    assert_operator window.bytesize, :<=, Erx::BenchMeasurement::WINDOW_LINE_BYTES
    assert_equal [9, 7, (1 << 64) - 1], Erx::BenchMeasurement.window(window).values_at('window', 'thread', 'waited')
  end
end
