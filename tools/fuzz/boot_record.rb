#!/usr/bin/env ruby
# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'optparse'
require_relative '../lib/erx/boot_record'

# The harness's slot parser (Erx::BootRecord.choose) over mutated record sectors and
# boot headers, as a guest that wrote the medium could leave them. Each input either
# raises Erx::Error and nothing else, or answers a choice that lies inside the slot
# its record commits, from the slot's boot start, at least a header long. Whether
# its answers are right is test/host/boot_record_test.rb's.
module Erx
  module BootRecordFuzz
    RECORD = BootRecord
    CODEC = RECORD::CODEC
    SLOT_BYTES = RECORD::SLOT_SECTORS * RECORD::SECTOR_BYTES

    module_function

    def header(image_size)
      CODEC.encode_layout(RECORD::HEADER, 'code0' => 0, 'code1' => 0, 'text_offset' => 0, 'image_size' => image_size,
                                          'flags' => 0xa, 'res2' => 0, 'res3' => 0, 'res4' => 0, 'res5' => 0).b
    end

    # Pairs of a record and a header: both slots, lengths at the bounds.
    def seeds
      room = SLOT_BYTES - (RECORD::BOOT_START * RECORD::SECTOR_BYTES)
      %i[a b].product([RECORD::HEADER_BYTES, 4096, room, room + 1, 0]).map do |slot, length|
        [RECORD.sector(slot), header(length)]
      end
    end

    def mutate(bytes, random)
      result = bytes.b.dup
      random.rand(1..3).times do
        next if result.empty?

        case random.rand(4)
        when 0 then result.setbyte(random.rand(result.bytesize), random.rand(256))
        when 1 then result = result.byteslice(0, random.rand(result.bytesize))
        when 2 then result.insert(random.rand(result.bytesize), random.bytes(random.rand(1..8)))
        else result.setbyte(random.rand(result.bytesize), [0, 0xff, 0x0a, 0x0d, 0x5b].sample(random: random))
        end
      end
      result
    end

    def exercise(record, header)
      choice = RECORD.choose(record: record, header: header)
      slot = RECORD::SLOTS.fetch(choice.slot)
      first = (slot.start + RECORD::BOOT_START) * RECORD::SECTOR_BYTES
      last = slot.start * RECORD::SECTOR_BYTES + SLOT_BYTES
      unless choice.slot == RECORD.committed(record) && choice.offset == first && choice.length >= RECORD::HEADER_BYTES && choice.offset + choice.length <= last
        raise "a choice outside its slot: #{choice.inspect}"
      end
    rescue Erx::Error
      nil
    end

    def run(seconds:, seed:)
      random = Random.new(seed)
      initial = seeds
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + seconds
      count = 0
      while Process.clock_gettime(Process::CLOCK_MONOTONIC) < deadline
        record, header = initial.sample(random: random)
        record = mutate(record, random) if random.rand(2).zero?
        header = mutate(header, random) if random.rand(4).positive?
        exercise(record, header)
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

  puts "boot record slot parser: #{Erx::BootRecordFuzz.run(**options)} inputs"
end
