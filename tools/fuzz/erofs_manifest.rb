#!/usr/bin/env ruby
# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'optparse'
require_relative '../lib/erx/erofs_manifest'

# The EROFS oracle's manifest parser (Erx::ErofsManifest.parse) over mutated serial
# transcripts, as a Linux guest or a broken console could leave them. Each input either
# raises Erx::Error and nothing else, or answers views whose every entry keeps the
# parser's promises: an absolute path of valid names within PATH_MAX, numbers within 64
# bits, and data of the entry's type. Whether its answers are right is
# test/host/erofs_oracle_test.rb's; comparing two answered views must not raise.
module Erx
  module ErofsManifestFuzz
    MANIFEST = ErofsManifest
    SUM = 'ab' * 32
    # The data each type carries when it is not an error.
    KIND = { regular: :sha256, symlink: :link, directory: :none, other: :none }.freeze

    module_function

    def line(text) = "#{MANIFEST::PREFIX}#{text}\r\n"

    def seeds
      entries = ['entry 2f 41ed 60 0 0 3 0 36 -', "entry 2f736d616c6c 81a4 100 0 0 2 0 54 sha256:#{SUM}",
                 'entry 2f746f2d736d616c6c a1ff 5 0 0 1 0 61 link:736d616c6c', 'entry 2f61 81a4 1 0 0 1 0 9 error:enotsup',
                 'entry 2f62 0 0 0 0 0 0 0 error:stat', "entry #{'2f' + ('61' * 300)} 41ed 18446744073709551615 0 0 1 0 1 -"]
      [
        "[    0.1] boot\n" + ['image 0', *entries, "end 0 #{entries.size}", 'refused 1 mount', 'done 2'].map { |text| line(text) }.join,
        ['refused 0 enotsup', 'done 1'].map { |text| line(text) }.join,
        ['image 0', 'end 0 0', 'done 1'].map { |text| line(text) }.join
      ]
    end

    def mutate(bytes, random)
      result = bytes.b.dup
      random.rand(1..4).times do
        next if result.empty?

        case random.rand(5)
        when 0 then result.setbyte(random.rand(result.bytesize), random.rand(256))
        when 1 then result = result.byteslice(0, random.rand(result.bytesize))
        when 2 then result.insert(random.rand(result.bytesize), random.bytes(random.rand(1..8)))
        when 3
          lines = result.lines
          result = lines.insert(random.rand(lines.size + 1), lines.sample(random: random)).join
        else result.setbyte(random.rand(result.bytesize), ' 0afe/:-'.bytes.sample(random: random))
        end
      end
      result
    end

    def exercise(bytes)
      views = MANIFEST.parse(bytes)
      views.each { |view| check(view) }
      views.each_cons(2) { |linux, reader| MANIFEST.compare(linux: linux, reader: reader) }
    rescue Erx::Error
      nil
    end

    def check(view)
      return if view.refusal && view.entries.nil?

      view.entries.each do |path, entry|
        names = path.split('/', -1).drop(1)
        valid = path == entry.path && path.start_with?('/') && path.bytesize <= MANIFEST::PATH_MAX &&
                (path == '/' || names.none? { |name| name.empty? || %w[. ..].include?(name) || name.include?("\0") }) &&
                [entry.size, entry.uid, entry.gid, entry.nlink, entry.mtime, entry.inode].all? { |n| n.between?(0, MANIFEST::U64_MAX) } &&
                entry.mode.between?(0, MANIFEST::MODE_MAX) &&
                (entry.data.first == :error || entry.data.first == KIND.fetch(entry.type, :error)) &&
                (entry.data.first != :link || (!entry.data.last.include?("                %i[none sha256 link error].include?(entry.data.first)
") && entry.data.last.bytesize.between?(1, MANIFEST::PATH_MAX - 1)))
        raise "the parser answered an entry that breaks its promises: #{entry.inspect}" unless valid
      end
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

  puts "EROFS oracle manifest parser: #{Erx::ErofsManifestFuzz.run(**options)} inputs"
end
