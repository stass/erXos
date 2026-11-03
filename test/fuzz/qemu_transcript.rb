#!/usr/bin/env ruby
# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'optparse'
require 'tmpdir'
require_relative '../../tools/lib/erx/qemu'

options = { seconds: 2, seed: 1_234_567 }
parser = OptionParser.new do |arguments|
  arguments.on('--seconds N', Integer) { |value| options[:seconds] = value }
  arguments.on('--seed N', Integer) { |value| options[:seed] = value }
end

begin
  remaining = parser.parse(ARGV)
  raise OptionParser::InvalidArgument, remaining.join(' ') unless remaining.empty?
  unless options.fetch(:seconds).between?(1, 3600) && options.fetch(:seed).between?(0, (1 << 64) - 1)
    raise OptionParser::InvalidArgument, 'seconds or seed outside bounds'
  end
  random = Random.new(options.fetch(:seed))
  deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + options.fetch(:seconds)
  cases = 0
  checkpoints = Erx::Qemu.boot_transcript(memory_mib: 512)
  summary = Erx::BootstrapMemory.summary(ram_bytes: 512 << 20).b.freeze
  Dir.mktmpdir('erx-qemu-fuzz-') do |directory|
    serial = File.join(directory, 'serial.log')
    until Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
      payload = random.bytes(random.rand(131_073))
      if random.rand(2).zero?
        payload = "Welcome to the L4Re Microkernel!\n".b + payload
      end
      if random.rand(2).zero?
        # The memory summary opens the boot transcript; a mutated copy
        # drives its verifier's rejection path.
        line = summary.dup
        line.setbyte(random.rand(line.bytesize), random.rand(256)) if random.rand(2).zero?
        payload = line + "\r\n".b + payload
      end
      if random.rand(2).zero?
        payload += "development build: trusted code only\n".b
      end
      File.binwrite(serial, payload)
      transcript = Erx::Transcript.new(checkpoints: checkpoints)
      begin
        # Production consumes at most 64 KiB per poll. Four polls include EOF
        # for this corpus, including its three injected checkpoint lines.
        4.times { transcript.consume(serial, elapsed: 0.0) }
      rescue Erx::Error
        # A bounded rejection is a valid parser result, not a fuzzer failure.
      end
      cases += 1
    end
  end
  Erx::Terminal.puts("QEMU transcript fuzz passed: #{cases} cases, seed #{options.fetch(:seed)}")
rescue OptionParser::ParseError => error
  Erx::Terminal.puts(error.message)
  exit 2
end
