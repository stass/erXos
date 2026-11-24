# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true
# erx-gate: sanitizers

require 'minitest/autorun'
require 'open3'
require 'tmpdir'
require 'fileutils'

# The guest bench library's pure cores on the host (docs/design-bench.md, "The histogram",
# "Profiles", "Verification"), through test/fixtures/bench_cores_driver.c: the
# histogram's buckets hold their samples and are at most 1/64 of their lower bound wide;
# a periodic schedule never moves a deadline, so a stall shows as missed periods and
# lateness, and a return before its deadline is early; the phase sweep visits sixteen
# phases, and a timer that fires only on ticks shows as a per-phase minimum that varies by
# about a tick; the cross-CPU offset is the causal interval of the calibration's rounds,
# and a cell across CPUs reports only when it is narrow and did not move. Seeded faults
# must each fail a check.
class BenchPeriodicTest < Minitest::Test
  ROOT = File.expand_path('../..', __dir__)
  SOURCES = %w[test/guest/bench/bench_hist.c test/guest/bench/bench_periodic.c test/guest/bench/bench_clock.c
               test/guest/bench/bench_line.c test/guest/bench/bench_window.c
               test/fixtures/bench_cores_driver.c].freeze
  EXPECTED = ['hist ok', 'stall ok', 'early ok', 'sweep ok', 'tick ok', 'offset ok', 'cell ok', 'drift ok', 'reads ok',
              'median ok', 'rounds ok', 'window ok'].freeze

  # name => [file, original, replacement]; each must turn a line of EXPECTED into a failure.
  MUTANTS = {
    'an off-by-one sub-bucket index' =>
      ['test/guest/bench/bench_hist.c', '(value >> (octave - 6)) & 63', '((value >> (octave - 6)) + 1) & 63'],
    'the next deadline taken in turn, not after the return' =>
      ['test/guest/bench/bench_periodic.c', "\twhile (erx_bench_periodic_deadline(first, period, next) <= returned)\n\t\tnext++;\n",
       ''],
    'the early test written <=' =>
      ['test/guest/bench/bench_periodic.c', 'stamps[i].returned < deadline', 'stamps[i].returned <= deadline'],
    'the phase term dropped' =>
      ['test/guest/bench/bench_periodic.c', '(uint64_t)erx_bench_periodic_phase(k) * period / ERX_BENCH_PHASES',
       '0'],
    'the stamps ordering test instead of the causal interval' =>
      ['test/guest/bench/bench_clock.c',
       "\t*low = (int64_t)round->b - (int64_t)round->c;\n\t*high = (int64_t)round->b - (int64_t)round->a;\n",
       "\t*low = 0;\n\t*high = 0;\n"],
    # Round one reads the token's zero before B can stamp: its interval cannot hold the offset.
    'thread A taking b before its round reaches B' =>
      ['test/guest/bench/bench_clock.c',
       "\t\tnumber++;\n\t\tatomic_store_explicit(&token->sent, number, memory_order_release);\n" \
       "\t\twhile (atomic_load_explicit(&token->answered, memory_order_acquire) != number)\n\t\t\t;\n" \
       "\t\tconst uint64_t c = read();\n" \
       "\t\tconst uint64_t b = atomic_load_explicit(&token->b, memory_order_relaxed);\n",
       "\t\tconst uint64_t b = atomic_load_explicit(&token->b, memory_order_relaxed);\n" \
       "\t\tnumber++;\n\t\tatomic_store_explicit(&token->sent, number, memory_order_release);\n" \
       "\t\twhile (atomic_load_explicit(&token->answered, memory_order_acquire) != number)\n\t\t\t;\n" \
       "\t\tconst uint64_t c = read();\n"],
    'a gap of exactly half the slice counted lost' =>
      ['test/guest/bench/bench_window.c', 'if (gap > lost_after) {', 'if (gap >= lost_after) {'],
    'a pass counted for a gap from before the window to past its end' =>
      ['test/guest/bench/bench_window.c', 'if (last >= start || now < end)', 'if (start <= end)']
  }.freeze

  def setup
    @directory = Dir.mktmpdir('erx-bench-periodic-')
    sanitizers = ENV.fetch('ERX_SANITIZERS', '').split(',').reject(&:empty?)
    @flags = sanitizers.empty? ? [] : ["-fsanitize=#{sanitizers.join(',')}", '-fno-omit-frame-pointer', '-fno-sanitize-recover=all']
  end

  def teardown = FileUtils.remove_entry(@directory)

  # A mutant may leave a parameter unused, which is not the fault it seeds.
  def build(sources, name:, mutant: false)
    output = File.join(@directory, name.tr(" '<=,", '-----'))
    log, status = Open3.capture2e(ENV.fetch('ERX_CLANG', 'clang'), '-std=c17', '-Wall', '-Wextra', '-Werror', '-pedantic', '-O1', '-pthread',
                                  '-g', *@flags, *(mutant ? ['-Wno-unused-parameter'] : []),
                                  '-I', ROOT, '-I', File.join(ROOT, 'test/guest/bench'), *sources, '-o', output, stdin_data: '')
    assert status.success?, log
    output
  end

  def answers(program)
    output, status = Open3.capture2e(program, stdin_data: '')
    assert status.success?, output
    output.lines.map(&:chomp)
  end

  def test_the_cores_answer_as_designed
    assert_equal EXPECTED, answers(build(SOURCES.map { |source| File.join(ROOT, source) }, name: 'driver'))
  end

  def test_each_seeded_fault_fails_a_check
    MUTANTS.each do |name, (file, original, replacement)|
      text = File.read(File.join(ROOT, file))
      assert_equal 1, text.scan(original).size, "#{name}: the original occurs once"
      mutated = File.join(@directory, File.basename(file))
      File.write(mutated, text.sub(original, replacement))
      sources = SOURCES.map { |source| source == file ? mutated : File.join(ROOT, source) }
      refute_equal EXPECTED, answers(build(sources, name: name, mutant: true)), name
    end
  end
end
