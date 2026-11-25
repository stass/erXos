#!/usr/bin/env ruby
# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true
# erx-gate: fuzz timed

require 'optparse'
require_relative '../lib/erx/bench_suite'
require_relative '../lib/erx/ipcbench'

# L4Re's importer (Erx::Ipcbench.import) over mutated ipcbench lines, as a guest could
# print them. Each input answers one cell per asked cell and raises nothing; a measured
# cell holds the program's calls and a mean that is its total over the program's count,
# and no refusal carries a control byte. Whether its answers are right is
# test/host/ipcbench_test.rb's.
module Erx
  module IpcbenchLineFuzz
    IPCBENCH = Ipcbench
    ASKED = IPCBENCH::PROGRAMS.map do |program|
      BenchSuite::LandingCell.new(operation: program.operation, load: 'idle', placement: 'same-cpu', parameters: {})
    end.freeze
    # The tokens that turn one field of a line into another.
    TOKENS = ['0', '9', ' ', '|', ':', 's', 'IPC', 'syscall', '18446744073709551616', "\e[31m", "\r", "\xff".b].freeze

    module_function

    def seeds
      IPCBENCH::PROGRAMS.map do |program|
        total = 1_000_003 * program.per_call
        "#{program.tag} | CPU  0 done #{program.count} #{program.word}s in #{total} cpu-cycles, " \
          "#{total / program.count} cpu-cycles/#{program.word}"
      end + ['ipc:1AS | caller: ipc err', 'ipc:PL | Found 4 CPUs.', 'Benchmarks done.']
    end

    # A seed's text mutated: bytes changed, cut or inserted.
    def mutate(text, random)
      result = text.b.dup
      random.rand(1..3).times do
        next if result.empty?

        case random.rand(4)
        when 0 then result.setbyte(random.rand(result.bytesize), random.rand(256))
        when 1 then result = result.byteslice(0, random.rand(result.bytesize))
        when 2 then result.insert(random.rand(result.bytesize), TOKENS.sample(random: random).b)
        else result.insert(random.rand(result.bytesize), random.bytes(random.rand(1..400)))
        end
      end
      result
    end

    def exercise(lines)
      answer = IPCBENCH.import(lines, benchmark: 'nullcall', cells: ASKED)
      raise 'an asked cell is missing' unless answer.fetch(:cells).map(&:operation) == ASKED.map(&:operation)

      answer.fetch(:cells).select { |cell| cell.status == 'measured' }.each do |cell|
        program = IPCBENCH::PROGRAMS.find { |candidate| candidate.operation == cell.operation }
        count, total, mean = cell.detail.values_at('count', 'total', 'mean')
        raise 'a measured mean is not its total over its count' unless count == IPCBENCH::CALLS && mean == total / program.count
      end
      raise 'a refusal carries a control byte' if answer.fetch(:refused).any? { |reason| reason.b.match?(/[\x00-\x1f\x7f]/n) }
    end

    def run(seconds:, seed:)
      random = Random.new(seed)
      initial = seeds
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + seconds
      count = 0
      while Process.clock_gettime(Process::CLOCK_MONOTONIC) < deadline
        exercise(initial.map { |line| random.rand(2).zero? ? mutate(line, random) : line }.shuffle(random: random))
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

  puts "ipcbench line importer: #{Erx::IpcbenchLineFuzz.run(**options)} inputs"
end
