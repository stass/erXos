#!/usr/bin/env ruby
# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'optparse'
require_relative '../lib/erx/hostlink_frame'

# The host tool's host link deframer and receiver (tools/lib/erx/hostlink_frame.rb) over
# mutated byte streams, fed in random pieces. Nothing raises, every result is one of the
# closed set, the pieces give what the whole stream gives, each frame taken re-encodes to
# itself, and the receiver's results are its closed set too. Its seeds are the shared
# vectors of test/fixtures/hostlink_frames.txt and a sender's messages. Whether its
# answers are right is test/host/hostlink_frame_test.rb's comparison with the vectors and
# with the Erlang layer.
module Erx
  module HostlinkFrameFuzz
    F = HostlinkFrame
    VECTORS = File.expand_path('../../test/fixtures/hostlink_frames.txt', __dir__)
    SESSION = ("\x07" * 16).b.freeze
    REASONS = %i[oversize cobs short crc version header stream].freeze
    RECEIVER_REASONS = %i[session seq control too_large pieces].freeze

    module_function

    def seeds
      vectors = File.readlines(VECTORS, chomp: true).filter_map do |line|
        words = line.split
        [words.last].pack('H*') if words.first == 'feed'
      end
      sender = F::Sender.new(SESSION)
      messages = sender.message(:reply, "\0\x01\x02".b * 6000, id: 1, target: 0).join +
                 sender.message(:cast, "\x83j".b, id: 0, target: 0).join + sender.frame(:events, 'log')
      [*vectors, messages, "#{"\xff".b * F::ENCODED_MAX}\0", "#{"\xff".b * (F::ENCODED_MAX + 1)}\0"]
    end

    def mutate(bytes, random)
      random.rand(0..3).times.reduce(bytes.b) do |result, _|
        next result if result.empty?

        at = random.rand(result.bytesize)
        case random.rand(5)
        when 0 then result.dup.tap { |copy| copy.setbyte(at, copy.getbyte(at) ^ (1 << random.rand(8))) }
        when 1 then result.byteslice(0, at)
        when 2 then result.dup.tap { |copy| copy.setbyte(at, 0) }
        when 3 then result + result
        else result.dup.tap { |copy| copy.setbyte(at, random.rand(256)) }
        end
      end
    end

    def pieces(bytes, random)
      at = 0
      [].tap do |result|
        while at < bytes.bytesize
          size = random.rand(1..600)
          result << bytes.byteslice(at, size)
          at += size
        end
      end
    end

    def exercise(bytes, random)
      side = %i[target host].sample(random: random)
      whole = F::Deframer.new(side).feed(bytes)
      deframer = F::Deframer.new(side)
      raise Error, 'pieces disagree with the whole' unless pieces(bytes, random).flat_map { |piece| deframer.feed(piece) } == whole

      whole.each { |result| closed(side, result) }
      receiver = F::Receiver.new.tap { |r| r.session = SESSION }
      whole.grep(F::Frame).each { |frame| accepted(receiver.accept(frame, room: random.rand(20_000))) }
      whole.grep(F::Frame).size
    end

    def closed(side, result)
      case result
      in F::Discard[reason] then raise Error, "unknown reason #{reason}" unless REASONS.include?(reason)
      in F::Frame => frame
        raise Error, 'a frame does not re-encode to itself' unless F::Deframer.new(side).feed(F.encode(frame)) == [frame]
      end
    end

    def accepted(result)
      case result
      in :pending | :skipped | F::Taken | F::Message | F::Hello | F::Refused then nil
      in F::Discard[reason] then raise Error, "unknown receiver reason #{reason}" unless RECEIVER_REASONS.include?(reason)
      end
    end

    def run(seconds:, seed:)
      random = Random.new(seed)
      initial = seeds
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + seconds
      count = 0
      taken = 0
      while Process.clock_gettime(Process::CLOCK_MONOTONIC) < deadline
        taken += exercise(mutate(initial.sample(random: random), random), random)
        count += 1
      end
      raise Error, "only #{taken} frames taken in #{count} inputs" unless taken > count / 10

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

  puts "host link deframer: #{Erx::HostlinkFrameFuzz.run(**options)} inputs"
end
