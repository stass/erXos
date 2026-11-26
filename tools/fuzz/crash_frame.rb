#!/usr/bin/env ruby
# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true
# erx-gate: fuzz timed

require 'optparse'
require_relative '../lib/erx/crash_frame'

# The harness's crash-frame reader over mutated frames. A status from its one
# set and nothing raised, a report of ASCII only, and a frame called valid
# holds a record the record check passes. Whether its answers are right is
# test/host/crash_test.rb's comparison with the C reader.
module Erx
  module CrashFrameFuzz
    STATUSES = %i[absent valid truncated corrupt].freeze
    FRAME = CrashFrame

    module_function

    NO_FAULT = { 'kind' => 0, 'cause' => 0, 'addr' => 0, 'pc' => 0, 'thread' => 0, 'space' => 0, 'status' => 0 }.freeze

    # A well-formed brief record, for seeds and tests to start past the CRC.
    def brief_record = record(form_name: 'brief', cause: :watchdog, fault: NO_FAULT)

    # A well-formed full record of an end of cause with fault's fields and text:
    # no registers, frames or CPU entries, as the Fiasco backend's end path
    # writes one. Every size and offset is the ABI file's.
    def full_record(cause:, fault:, text:) = record(form_name: 'full', cause: cause, fault: NO_FAULT.merge(fault), text: text)

    def record(form_name:, cause:, fault:, text: '')
      body = form_name == 'full' ? ("\0".b * (FRAME::RECORD_SIZE - FRAME::BRIEF_SIZE)) + text.b : ''.b
      fields = { 'magic' => FRAME::CODEC.constant('crash_magic'), 'version' => FRAME::CODEC.constant('crash_version'),
                 'length' => FRAME::BRIEF_SIZE + body.bytesize, 'crc' => 0, 'form' => FRAME::FORMS.fetch(form_name),
                 'cause' => FRAME::CAUSE.fetch(cause), 'cpu' => 0, 'uptime_ns' => 1, 'since_pet_ns' => 1,
                 'build_id' => 'BUILDID8', 'boot_value' => FRAME::VALUE_UNKNOWN, 'boot_slot' => FRAME::SLOT_NONE,
                 'nframes' => 0, 'ncpus' => 0, 'fault' => fault }
      record = FRAME::CODEC.encode_layout('erx_crash_brief', fields) + body
      record[FRAME::CRC_START - 4, 4] = [FRAME.crc32c(record.byteslice(FRAME::CRC_START..))].pack('L<')
      record
    end
    private_class_method :record

    # The frame of a record's bytes, under the header line asked for.
    def frame_of(record, form_name: nil, length: nil)
      length ||= record.bytesize
      form_name ||= record.bytesize == FRAME::BRIEF_SIZE ? 'brief' : 'full'
      payload = record.b.scan(/.{1,#{FRAME::LINE_BYTES}}/mn).map { |line| [line].pack('m0') }
      ["#{FRAME::BEGIN_MARKER} #{form_name} #{length}", *payload, FRAME::END_MARKER].join("\n") << "\n"
    end

    def seeds
      frame = frame_of(brief_record)
      [frame, "text\n#{frame}tail\n", frame.gsub("\n", "\r\n"), "#{FRAME::BEGIN_MARKER} full #{FRAME::RECORD_SIZE}\n", frame.lines[0...-1].join]
    end

    def mutate(bytes, random)
      result = bytes.b.dup
      random.rand(1..4).times do
        next if result.empty?

        case random.rand(4)
        when 0 then result.setbyte(random.rand(result.bytesize), random.rand(256))
        when 1 then result = result.byteslice(0, random.rand(result.bytesize))
        when 2 then result.setbyte(random.rand(result.bytesize), 10)
        else result.insert(random.rand(result.bytesize), ['=', "\r", "\e[31m", FRAME::END_MARKER, FRAME::BEGIN_MARKER].sample(random: random))
        end
      end
      result
    end

    def exercise(bytes)
      result = FRAME.read(bytes)
      raise Error, "unknown status #{result.status}" unless STATUSES.include?(result.status)
      raise Error, 'a report holds a raw byte' unless FRAME.report(result).all? { |line| line.match?(/\A[\x20-\x7e]*\z/) }
      raise Error, 'a valid frame without its record' if result.status == :valid && result.record.nil?
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

  puts "crash frame reader: #{Erx::CrashFrameFuzz.run(**options)} inputs"
end
