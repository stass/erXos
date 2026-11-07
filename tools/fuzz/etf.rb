#!/usr/bin/env ruby
# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'optparse'
require_relative '../lib/erx/etf'

# The host tool's term decoder over mutated encodings of the host grammar.
# For every input it returns a value or raises one of the codec's own
# errors, whose message is printable ASCII, as it may reach the operator's
# terminal; and a value it returns encodes, and decodes from that encoding
# to the same value and the same bytes again. Whether its answers are
# right is test/integration/etf_oracle_test.rb's comparison with stock OTP.
module Erx
  module EtfFuzz
    Etf = Erx::Etf
    MAX_INPUT = 4096
    # Tags and lengths that steer a mutation into the grammar's edges.
    INTERESTING = [[0], [255], [255, 255, 255, 255], [0, 0, 0, 0], [106], [107], [108], [104], [105],
                   [116], [67], [77], [70], [110], [111], [118], [119], [88], [90], [131]].map { |bytes| bytes.pack('C*') }.freeze

    module_function

    def seeds
      atom = ->(name) { Etf::Atom[name] }
      values = [
        0, 255, -1, 2**31, -(2**70), 1.5, -0.0, atom.call('ok'), atom.call("\u00e9" * 3), ''.b, 'bytes'.b,
        Etf::Bitstring["\xf0".b, 5], Etf::Tuple[[]], Etf::Tuple[[atom.call('ok'), 1]], Etf::Tuple[(1..300).to_a],
        [], [1, 2, 3], [300, atom.call('a')], Etf::ImproperList[[1, 2], atom.call('t')],
        {}, { atom.call('k') => [1], 2.0 => { 3 => 'v'.b } },
        Etf::Record[module_name: atom.call('m'), name: atom.call('r'), exported: true,
                    fields: { atom.call('a') => 1, atom.call('b') => [Etf::Tuple[[]]] }],
        Etf::Tuple[[atom.call('reply'), [Etf::Tuple[[atom.call('$host_cap'), 3]], { atom.call('n') => 'x'.b }]]]
      ]
      values.map { |value| Etf.encode(value) } + [[131, 108, 0, 0, 0, 1, 97, 1, 107, 0, 1, 2].pack('C*')]
    end

    def mutate(bytes, random)
      result = bytes.b.dup
      random.rand(1..4).times do
        break if result.empty?

        position = random.rand(result.bytesize)
        case random.rand(5)
        when 0 then result.setbyte(position, random.rand(256))
        when 1 then result = result.byteslice(0, position)
        when 2 then result.insert(position, INTERESTING.sample(random: random))
        when 3 then result[position, 4] = INTERESTING.sample(random: random)
        else result.insert(position, result.byteslice(position, random.rand(1..16)))
        end
      end
      result.byteslice(0, MAX_INPUT)
    end

    def exercise(bytes)
      value = Etf.decode(bytes)
    rescue Etf::Error => e
      raise Error, "an error message holds a raw byte: #{e.message.dump}" unless e.message.match?(/\A[\x20-\x7e]*\z/)
    else
      encoded = Etf.encode(value)
      again = Etf.decode(encoded)
      raise Error, "decoding #{bytes.unpack1('H*')} does not round trip" unless again.eql?(value)
      raise Error, "encoding #{bytes.unpack1('H*')} is not stable" unless Etf.encode(again) == encoded
    end

    def run(seconds:, seed:)
      random = Random.new(seed)
      initial = seeds
      initial.each { |bytes| exercise(bytes) }
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + seconds
      count = initial.size
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

  puts "term decoder: #{Erx::EtfFuzz.run(**options)} inputs"
end
