#!/usr/bin/env ruby
# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'optparse'
require_relative '../lib/erx/error'
require_relative '../lib/erx/json_input'
require_relative '../lib/erx/line_escape'

# The host tool's line escape, Erx::LineEscape, over random bytes and
# mutations of the shared vectors' inputs. For every input its answer must be
# valid UTF-8 holding no character the tables mark unsafe, must stay as it is
# when escaped again, and must agree with a reference of this file's own,
# which decodes by Ruby's own UTF-8 validity rather than by the escape's
# regular expression and searches the ranges one by one. That the escape
# agrees with erx_text is the shared vectors' test.
module Erx
  module LineEscapeFuzz
    MAX_INPUT = 256
    VECTORS = File.expand_path('../../test/fixtures/line_escape_vectors.json', __dir__)
    STEERING = [0, 9, 10, 27, 0x5c, 0x3c, 0x7f, 0x80, 0x9b, 0xbf, 0xc0, 0xc2, 0xe0, 0xe2, 0xed, 0xef, 0xf0, 0xf4,
                0xf5, 0xff].freeze
    RANGES = Generated::TerminalTables::UNICODE_UNSAFE_RANGES
    TOKENS = Generated::TerminalTables::CATALOG.fetch('token')

    module_function

    def seeds
      JsonInput.parse(File.binread(VECTORS), label: 'line escape vectors').fetch('vectors').map { |vector| [vector.fetch('input')].pack('H*') }
    end

    def byte(random) = random.rand(2).zero? ? STEERING.sample(random: random) : random.rand(256)

    def mutate(bytes, random)
      result = bytes.b.dup
      random.rand(1..4).times do
        position = result.empty? ? 0 : random.rand(result.bytesize)
        case random.rand(3)
        when 0 then result.insert(position, byte(random).chr)
        when 1 then result = result.byteslice(0, position)
        else result.insert(position, Array.new(random.rand(1..4)) { byte(random) }.pack('C*'))
        end
      end
      result.byteslice(0, MAX_INPUT)
    end

    def exercise(bytes)
      output = LineEscape.escape(bytes)
      shown = bytes.unpack1('H*')
      raise Error, "escape of #{shown} is not valid UTF-8" unless output.valid_encoding?
      raise Error, "escape of #{shown} holds an unsafe character" if output.each_char.any? { |c| unsafe?(c.ord) }
      raise Error, "escape of #{shown} is not stable" unless LineEscape.escape(output) == output
      raise Error, "escape of #{shown} differs from the reference" unless reference(bytes) == output
    end

    # One character at a time: the longest prefix of up to four bytes that
    # Ruby takes as one valid UTF-8 character, or else one byte.
    def reference(bytes)
      output = +''
      rest = bytes.b
      until rest.empty?
        length = (1..4).find { |size| valid_character?(rest.byteslice(0, size)) }
        if length
          point = rest.byteslice(0, length).force_encoding(Encoding::UTF_8).ord
          output << (unsafe?(point) ? token(point, 'codepoint') : rest.byteslice(0, length))
        else
          output << token(rest.getbyte(0), 'byte')
        end
        rest = rest.byteslice((length || 1)..)
      end
      output.force_encoding(Encoding::UTF_8)
    end

    def valid_character?(bytes)
      text = bytes.dup.force_encoding(Encoding::UTF_8)
      text.valid_encoding? && text.length == 1
    end

    def unsafe?(point) = RANGES.any? { |first, last| point.between?(first, last) }

    def token(value, name)
      spec = TOKENS.fetch(name)
      "#{spec.fetch('prefix')}#{format('%0*X', spec.fetch('minimum'), value)}#{spec.fetch('suffix')}"
    end

    def run(seconds:, seed:)
      random = Random.new(seed)
      initial = seeds
      initial.each { |bytes| exercise(bytes) }
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + seconds
      count = initial.size
      while Process.clock_gettime(Process::CLOCK_MONOTONIC) < deadline
        input = if random.rand(3).zero?
                  Array.new(random.rand(0..64)) { byte(random) }.pack('C*')
                else
                  mutate(initial.sample(random: random), random)
                end
        exercise(input)
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

  puts "line escape: #{Erx::LineEscapeFuzz.run(**options)} inputs"
end
