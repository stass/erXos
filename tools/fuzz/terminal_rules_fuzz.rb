# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require_relative '../lib/erx/terminal_rules'

module Erx
  module TerminalRulesFuzz
    module_function

    def run(root:, iterations: 20_000, seed: 1)
      raise Error, 'invalid terminal fuzz bound' unless iterations.is_a?(Integer) && iterations.between?(1, 1_000_000)
      seeds = [File.binread(File.join(root, 'abi/terminal.txt')),
               "0041;LATIN CAPITAL LETTER A;Lu;0;L;;;;;N;;;;;\n".b,
               "10000;<Fixture, First>;Lo;0;L;;;;;N;;;;;\n10002;<Fixture, Last>;Lo;0;L;;;;;N;;;;;\n".b,
               "# DerivedCoreProperties-17.0.0.txt\n034F ; Default_Ignorable_Code_Point\n".b]
      random = Random.new(seed)
      iterations.times do |index|
        kind = index % seeds.size
        bytes = seeds[kind].dup
        random.rand(1..8).times do
          if random.rand(4).zero?
            bytes = bytes.byteslice(0, random.rand(0..bytes.bytesize))
          elsif !bytes.empty?
            bytes.setbyte(random.rand(bytes.bytesize), random.rand(256))
          end
        end
        begin
          case kind
          when 0 then TerminalRules.source(bytes)
          when 1, 2 then TerminalRules.unicode_data(bytes)
          when 3 then TerminalRules.derived_properties(bytes, version: '17.0.0')
          end
        rescue Error
          # Invalid source is an ordinary refusal; other exceptions are bugs.
        end
      end
      { 'iterations' => iterations, 'seed' => seed }.freeze
    end
  end
end

if $PROGRAM_NAME == __FILE__
  puts JSON.generate(Erx::TerminalRulesFuzz.run(root: File.expand_path('../..', __dir__)))
end
