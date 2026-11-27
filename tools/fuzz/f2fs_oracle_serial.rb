#!/usr/bin/env ruby
# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true
# erx-gate: fuzz timed

require 'base64'
require 'digest'
require 'optparse'
require_relative '../lib/erx/f2fs_oracle_guest'

# The F2FS oracle guest's serial reader (Erx::F2fsOracleGuest.read, docs/design-f2fs.md,
# "The Linux oracle guest") over mutated serial logs, as a console shared with a kernel
# running a hostile image could deliver them, and fsck_verdict over what it answers.
# Each input either raises Erx::Error and nothing else, its message free of control
# bytes, or answers a Batch that holds only the names asked for, only the steps and
# statuses the grammar names, a status only beside its step's output, and a kernel
# release of the grammar's form; each verdict is :pass or a message free of control
# bytes. Whether its answers are right is test/host/f2fs_oracle_guest_test.rb's.
module Erx
  module F2fsOracleSerialFuzz
    GUEST = F2fsOracleGuest
    NAMES = %w[vault linux-vault].freeze
    # The tokens that turn one field of a line into another, or one line into two.
    TOKENS = [GUEST::PREFIX, ' ', "\r", "\n", "\r\n", '=', 'out', 'size', 'exit', 'done', 'kernel', 'vault', 'fsck', '0',
              '999', '1000', "\e[2J", "\e]8;;x\a", "\xff".b, "\u202e"].freeze
    CONTROL = /[\x00-\x1f\x7f]|\xc2[\x80-\x9f]|\xe2\x80[\xa8-\xae]/n

    module_function

    # A step's lines as the guest prints them: its chunks, then its size line.
    def step(name, step, bytes)
      chunks = Base64.strict_encode64(bytes).scan(/.{1,24}/).map { |chunk| "#{GUEST::PREFIX}out #{name} #{step} #{chunk}" }
      [*chunks, "#{GUEST::PREFIX}size #{name} #{step} #{bytes.bytesize} #{Digest::SHA256.hexdigest(bytes)}"]
    end

    def seed
      record = [['.', 'd', '755', '2', '3', '4096', ''], ['./a', 'f', '644', '1', '4', '0', "=#{'0' * 64}"]]
      images = NAMES.flat_map do |name|
        [*step(name, 'fsck', "Info: ok\n[FSCK] fixing SIT types\n"), "#{GUEST::PREFIX}exit #{name} fsck 0",
         *step(name, 'mount', ''), "#{GUEST::PREFIX}exit #{name} mount 0",
         *step(name, 'list', record.flatten.map { |field| "#{field}\0" }.join), "#{GUEST::PREFIX}exit #{name} list 0",
         *step(name, 'dmesg', "[ 3.1] F2FS-fs (loop0): Mounted\n")]
      end
      ['[    0.0] Booting Linux', "\e[?25l", "#{GUEST::PREFIX}kernel 7.0.0-34-generic", *images, "#{GUEST::PREFIX}done"]
    end

    # A seed's lines mutated: a line's bytes changed, cut or inserted, or a line dropped,
    # doubled or moved.
    def mutate(lines, random)
      result = lines.map { |line| line.b.dup }
      random.rand(1..3).times do
        at = random.rand(result.size)
        line = result[at]
        case random.rand(7)
        when 0 then line.setbyte(random.rand(line.bytesize), random.rand(256)) unless line.empty?
        when 1 then result[at] = line.byteslice(0, random.rand(line.bytesize + 1))
        when 2 then line.insert(random.rand(line.bytesize + 1), TOKENS.sample(random: random).b)
        when 3 then result.delete_at(at)
        when 4 then result.insert(at, line.dup)
        when 5 then result.delete_at(at).then { |moved| result.insert(random.rand(result.size + 1), moved) }
        else line.insert(random.rand(line.bytesize + 1), random.bytes(random.rand(1..40)))
        end
        result = [''] if result.empty?
      end
      result
    end

    # Answers whether the reader accepted the input.
    def exercise(lines, separator)
      batch = GUEST.read(lines.join(separator), names: NAMES)
      raise 'a result for a name never asked for' unless (batch.results.keys - NAMES).empty?
      raise 'a kernel release of no known form' unless batch.kernel.nil? || batch.kernel.match?(GUEST::RELEASE)

      batch.results.each_value do |result|
        raise 'a step of no known form' unless (result.outputs.keys - GUEST::STEPS).empty?
        raise 'a status of no known form' unless (result.statuses.keys - GUEST::STATUS_STEPS).empty?
        raise 'a status without its output' unless (result.statuses.keys - result.outputs.keys).empty?
        raise 'a status out of range' unless result.statuses.values.all? { |code| code.between?(0, 999) }

        verdict = GUEST.fsck_verdict(result, control: batch.results.fetch('linux-vault', result))
        raise 'a verdict carries a control byte' unless verdict == :pass || !verdict.b.match?(CONTROL)
      end
      true
    rescue Error => e
      raise "a refusal carries a control byte: #{e.message.inspect}" if e.message.b.match?(CONTROL)

      false
    end

    def run(seconds:, seed:)
      random = Random.new(seed)
      initial = self.seed
      raise "the seed does not read" unless GUEST.read(initial.join("\r\n"), names: NAMES).done

      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + seconds
      count = 0
      accepted = 0
      while Process.clock_gettime(Process::CLOCK_MONOTONIC) < deadline
        accepted += 1 if exercise(mutate(initial, random), ["\r\n", "\n", "\r\r\n"].sample(random: random))
        count += 1
      end
      # About one input in twelve reads; none means the mutations reach no answer.
      raise 'the reader accepted no mutated input' if count >= 100 && accepted.zero?

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

  puts "f2fs oracle serial reader: #{Erx::F2fsOracleSerialFuzz.run(**options)} inputs"
end
