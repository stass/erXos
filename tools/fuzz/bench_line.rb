#!/usr/bin/env ruby
# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true
# erx-gate: fuzz timed

require 'json'
require 'optparse'
require_relative '../lib/erx/bench_measurement'

# The BENCH, CLOCK and WINDOW line validators (Erx::BenchMeasurement.cell, .clock and
# .window) over mutated lines, as a guest could print them.
# Each input either raises Erx::Error and nothing else, or answers a clock group, a
# window of a line within its bound, or a cell whose histogram holds no more samples than
# its profile asked for. Whether its
# answers are right is test/host/bench_line_test.rb's.
module Erx
  module BenchLineFuzz
    MEASUREMENT = BenchMeasurement
    PROFILES = {
      'park-deadline' => BenchRecord::Profile.new(name: 'periodic', warmup: 0, samples: 32, runs: 1),
      'wake-same-cpu' => BenchRecord::Profile.new(name: 'fast', warmup: 10, samples: 40, runs: 1),
      'trigger-take' => BenchRecord::Profile.new(name: 'expensive', warmup: 10, samples: 20, runs: 1)
    }.freeze
    # JSON's own tokens and a float, inserted where they turn one value into another.
    TOKENS = ['0', '9', '-', ',', ']', '[', '{', '}', '"', '1e3', '5.0', 'null', '\udc00', '/*'].freeze

    module_function

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
      if profile.name == 'periodic'
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

    def seeds = PROFILES.keys.map { |operation| line(operation) } + [clock_line, window_line, longest_window_line]

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
      return MEASUREMENT.clock(text) if text.start_with?('CLOCK')
      if text.start_with?('WINDOW')
        MEASUREMENT.window(text)
        raise 'an accepted WINDOW line past its bound' if text.bytesize > MEASUREMENT::WINDOW_LINE_BYTES

        return
      end

      cell = MEASUREMENT.cell(text, benchmark: 'wake', profiles: PROFILES)
      samples = cell.summary.fetch('samples', 0)
      raise 'an accepted histogram past its profile' if samples > PROFILES.fetch(cell.operation).samples
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

  puts "BENCH, CLOCK and WINDOW line validators: #{Erx::BenchLineFuzz.run(**options)} inputs"
end
