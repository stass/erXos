#!/usr/bin/env ruby
# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true
# erx-gate: fuzz timed

require 'json'
require 'optparse'
require_relative '../lib/erx/bench_measurement'
require_relative '../lib/erx/bench_suite'
require_relative '../lib/erx/board_log'

# The BENCH, CLOCK and WINDOW line validators (Erx::BenchMeasurement.cell, .clock and
# .window) over mutated lines, as a guest could print them, and the board log's reader
# (Erx::BoardLog) over mutated board logs, as a console could deliver them.
# Each input either raises Erx::Error and nothing else, or answers a clock group, a
# window of a line within its bound, or a cell whose histogram holds no more samples
# than its profile asked for, or, for a board log, one boot per entry whose slices are
# the log. Whether its answers are right is test/host/bench_line_test.rb's and
# test/host/board_log_test.rb's.
module Erx
  module BenchLineFuzz
    MEASUREMENT = BenchMeasurement
    PROFILES = {
      'park-deadline' => BenchRecord::Profile.new(name: 'periodic', warmup: 0, samples: 32, runs: 1),
      'wake-same-cpu' => BenchRecord::Profile.new(name: 'fast', warmup: 10, samples: 40, runs: 1),
      'trigger-take' => BenchRecord::Profile.new(name: 'expensive', warmup: 10, samples: 20, runs: 1),
      'erlang-timer' => BenchRecord::Profile.new(name: 'periodic', warmup: 0, samples: 24, runs: 1)
    }.freeze
    WAKE = BenchSuite.benchmark('wake')
    # The one benchmark the lines report, at PROFILES' sizes; cell checks no declared cell.
    ASKED = BenchMeasurement::Asked.new(
      benchmarks: [BenchMeasurement::Wanted.new(benchmark: WAKE, cells: [], profiles: PROFILES)],
      clock: 'counter', pairs: [[0, 1]]
    )
    # JSON's own tokens and a float, inserted where they turn one value into another.
    TOKENS = ['0', '9', '-', ',', ']', '[', '{', '}', '"', '1e3', '5.0', 'null', '\udc00', '/*'].freeze

    # A board log's three bench entries, their sets and the found pair's banner
    # (docs/design-bench.md, "Importing a log"), in the guest's line format.
    BOARD_NAMES = %w[0123456789abcdef0123456789abcdef 89abcdef0123456789abcdef01234567
                     fedcba9876543210fedcba9876543210].freeze
    BOARD_OPERATIONS = %w[wake-same-cpu trigger-take park-deadline].freeze
    FOUND = { build: '00c0ffee00c0ffee', index: 'ab' * 32 }.freeze
    BENCH_BUILD = { build: '1234567890abcdef', index: 'cd' * 32 }.freeze
    # What the bootloader and the firmware print before each boot's kernel.
    FIRMWARE_LINES = ['RPi: BOOTLOADER release VERSION:a1b2c3d4 DATE: 2026/01/01', 'HTTP: GET boot.sig',
                      'HTTP: GET boot.img', 'MESS:00:00:05.012712:0: arasan: arasan_emmc_open'].freeze

    module_function

    def board_queue
      BoardFiles::Queue.new(
        benchmark: 'wake', sets: [BoardFiles::BootSet.new(directory: 'build/bench-board/wake', record_sha256: 'ee' * 32)],
        entries: BOARD_NAMES.each.with_index(1).map do |name, position|
          BoardFiles::Entry.new(position: position, name: name, set: 0, image_sha256: format('%064x', position))
        end,
        return_identity: BoardFiles::Identity.new(**FOUND)
      )
    end

    # What each entry's set asks: BOARD_OPERATIONS at PROFILES' sizes, on two CPUs.
    def board_asked
      cells = BOARD_OPERATIONS.map { |operation| BenchSuite::LandingCell.new(operation: operation, load: 'idle', placement: 'same-cpu', parameters: {}) }
      [BenchMeasurement::Asked.new(benchmarks: [BenchMeasurement::Wanted.new(benchmark: WAKE, cells: cells, profiles: PROFILES)],
                                   clock: 'counter', pairs: [[0, 1]])]
    end

    def banner(build:, index:) = "erx: boot image build #{build} index #{index} flags 0x1 archive 0x40231000+0x2e000 bootargs 2"

    # One entry's boot as the bench root prints it: the firmware's lines, the banner, a
    # naming line after the root is up and after each BENCH and CLOCK line, and the end.
    def entry_lines(name)
      [*FIRMWARE_LINES, banner(**BENCH_BUILD), 'erx: entropy: quality: low, from the counter alone',
       "erx: bench: boot #{name}", 'erx: bench: timing',
       *[*BOARD_OPERATIONS.map { |operation| line(operation) }, clock_line].flat_map { |text| [text, "erx: bench: boot #{name}"] },
       "erx: bench: boot #{name} done", 'erx: end reset']
    end

    # A board log of the three entries and the found pair's boot, in serial's line ends.
    def board_lines = [*BOARD_NAMES.flat_map { |name| entry_lines(name) }, *FIRMWARE_LINES, banner(**FOUND), 'erXos']
    def board_log(lines = board_lines) = lines.map { |text| "#{text}\r\n" }.join

    # A valid line for operation: samples spread over a few buckets, the fields its
    # profile adds, and overrides merged over the top level.
    def line(operation, **overrides)
      profile = PROFILES.fetch(operation)
      samples = (0...profile.samples).map { |index| 1000 + (index * 37 % 200) }
      buckets = samples.tally.sort.map { |value, count| [value, value, count] }
      fields = {
        'benchmark' => 'wake', 'operation' => operation,
        'conditions' => { 'load' => 'idle', 'placement' => 'same-cpu', 'parameters' => {}, 'clock' => 'counter',
                          'batch' => 1 },
        'frequency_hz' => 24_000_000, 'status' => 'measured', 'samples' => samples.size, 'histogram' => buckets,
        'min' => samples.min, 'max' => samples.max,
        'largest' => samples.each_with_index.max_by([16, samples.size].min) { |value, index| [value, -index] }.map(&:reverse),
        'counts' => { 'lost' => 0, 'early' => 0, 'missed' => 0 }
      }
      fields['raw'] = samples if profile.name == 'expensive'
      if profile.name == 'periodic' && WAKE.operations.fetch(operation).sweep
        fields['phases'] = (0...16).map { |phase| [5, samples.size / 16 + (phase < samples.size % 16 ? 1 : 0)] }
        fields['excess'] = buckets
      end
      "BENCH #{JSON.generate(fields.merge(overrides.transform_keys(&:to_s)))}"
    end

    # A valid CLOCK line, a two-CPU guest's calibration, and overrides merged over it.
    def clock_line(**overrides)
      fields = { 'clock' => 'counter', 'frequency_hz' => 24_000_000, 'increment' => 1, 'read_cost' => 2,
                 'wait_rounding' => 24, 'cycles_per_tick' => 'unknown',
                 'pairs' => [{ 'cpus' => [0, 1], 'before' => [-40, 12], 'after' => [-35, 15] }] }
      "CLOCK #{JSON.generate(fields.merge(overrides.transform_keys(&:to_s)))}"
    end

    # A valid WINDOW line, a thread's window as a spinner writes it, and overrides merged over it.
    def window_line(**overrides)
      fields = { 'window' => 0, 'thread' => 2, 'iterations' => 81_234_567, 'longest' => 98_765, 'lost' => 250,
                 'waited' => 18_000_000 }
      "WINDOW #{JSON.generate(fields.merge(overrides.transform_keys(&:to_s)))}"
    end

    # The longest WINDOW line a spinner writes: its last window and thread, every count at its most.
    def longest_window_line = window_line(window: 9, thread: 7, **MEASUREMENT::WINDOW_COUNTS.to_h { |name| [name, (1 << 64) - 1] })

    # Each operation's line, the two-CPU calibration, an Erlang guest's: 1 GHz, its wait
    # rounding 1 ms, cycles unknown, no pair, and a failed cell with samples; and WINDOW
    # lines, a typical one and the longest.
    def seeds
      PROFILES.keys.map { |operation| line(operation) } +
        [clock_line, clock_line(frequency_hz: 1_000_000_000, increment: 41, wait_rounding: 1_000_000, pairs: []),
         line('erlang-timer', frequency_hz: 1_000_000_000, status: 'failed', reason: 'a timer message did not come',
                              counts: { 'lost' => 1, 'early' => 0, 'missed' => 3 }),
         window_line, longest_window_line, board_log]
    end

    # A seed's text mutated: bytes changed, cut or inserted, and the histogram's first
    # bucket repeated.
    def mutate(text, random)
      result = text.b.dup
      random.rand(1..3).times do
        next if result.empty?

        case random.rand(5)
        when 0 then result.setbyte(random.rand(result.bytesize), random.rand(256))
        when 1 then result = result.byteslice(0, random.rand(result.bytesize))
        when 2 then result.insert(random.rand(result.bytesize), TOKENS.sample(random: random))
        when 3 then result.insert(random.rand(result.bytesize), random.bytes(random.rand(1..4)))
        else result = repeat_bucket(result, random.rand(1..5000))
        end
      end
      result
    end

    def repeat_bucket(text, times)
      text.sub(/"histogram":\[(\[\d+,\d+,\d+\]),/) { "\"histogram\":[#{([Regexp.last_match(1)] * times).join(',')}," }
    end

    def exercise(text)
      return board(text) if text.include?("\n")
      return MEASUREMENT.clock(text) if text.start_with?('CLOCK')
      if text.start_with?('WINDOW')
        MEASUREMENT.window(text)
        raise 'an accepted WINDOW line past its bound' if text.bytesize > MEASUREMENT::WINDOW_LINE_BYTES

        return
      end

      cell = MEASUREMENT.cell(text, ASKED)
      samples = cell.summary.fetch('samples', 0)
      raise 'an accepted histogram past its profile' if samples > PROFILES.fetch(cell.operation).samples
    rescue Erx::Error
      nil
    end

    def board(text)
      queue = board_queue
      read = BoardLog.read(text, queue: queue, asked: board_asked)
      raise 'a board log read into another count of boots' unless read.boots.size == queue.entries.size
      raise "a board log's slices are not the log" unless read.boots.map(&:log).join == text.b
    rescue Erx::Error
      nil
    end

    def run(seconds:, seed:)
      random = Random.new(seed)
      initial = seeds
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + seconds
      count = 0
      while Process.clock_gettime(Process::CLOCK_MONOTONIC) < deadline
        exercise(mutate(initial.sample(random: random), random))
        count += 1
      end
      count
    end
  end
end

if $PROGRAM_NAME == __FILE__
  options = { seconds: 3, seed: 1 }
  OptionParser.new do |arguments|
    arguments.on('--seconds N', Integer) { |value| options[:seconds] = value }
    arguments.on('--seed N', Integer) { |value| options[:seed] = value }
  end.parse!(ARGV)
  raise OptionParser::InvalidArgument, 'budget of 1..60 seconds' unless options[:seconds].between?(1, 60)

  puts "BENCH, CLOCK and WINDOW line validators and the board log reader: #{Erx::BenchLineFuzz.run(**options)} inputs"
end
