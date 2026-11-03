#!/usr/bin/env ruby
# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'optparse'
load File.expand_path('../../tools/erx', __dir__)

options = { seconds: 3, seed: 1 }
begin
  OptionParser.new do |flags|
    flags.on('--seconds N', Integer) { |value| options[:seconds] = value }
    flags.on('--seed N', Integer) { |value| options[:seed] = value }
  end.parse!(ARGV)
  unless ARGV.empty? && options.fetch(:seconds).between?(1, 60) && options.fetch(:seed).between?(0, (1 << 31) - 1)
    raise OptionParser::InvalidArgument, 'status fuzz budget or seed outside bounds'
  end
  seed = JSON.generate('state' => 'running', 'argv' => ['fixture'],
                       'started_at' => '2026-01-01T00:00:00Z', 'deadline_seconds' => 30,
                       'log' => '/fixture.log').b
  random = Random.new(options.fetch(:seed))
  deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + options.fetch(:seconds)
  count = 0
  until Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
    bytes = seed.dup
    if random.rand(2).zero?
      bytes = bytes.byteslice(0, random.rand(bytes.bytesize + 1))
    else
      random.rand(1..8).times { bytes.setbyte(random.rand(bytes.bytesize), random.rand(256)) }
    end
    begin
      Erx::CLI.send(:status_record, bytes)
    rescue Erx::Error
      # A typed refusal is valid. Unexpected exceptions fail the target.
    end
    count += 1
  end
  Erx::Terminal.puts("runner status: #{count} inputs, seed #{options.fetch(:seed)}")
rescue OptionParser::ParseError => error
  Erx::Terminal.puts(error.message)
  exit 2
end
