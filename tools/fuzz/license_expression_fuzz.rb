# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require_relative '../lib/erx/license_expression'
require 'json'

module Erx
  module LicenseExpressionFuzz
    module_function

    def run(iterations: 20_000, seed: 1)
      raise Error, 'invalid licence fuzz bound' unless iterations.is_a?(Integer) && iterations.between?(1, 1_000_000)
      random = Random.new(seed)
      seeds = ['BSD-3-Clause OR GPL-2.0-only', '(MIT OR ISC) AND Apache-2.0 WITH LLVM-exception',
               'GPL-3.0-or-later WITH GCC-exception-3.1', '('*32 + 'MIT' + ')'*32]
      iterations.times do |index|
        bytes = seeds[index % seeds.size].b
        random.rand(1..6).times do
          if random.rand(4).zero?
            bytes = bytes.byteslice(0, random.rand(0..bytes.bytesize))
          elsif !bytes.empty?
            bytes.setbyte(random.rand(bytes.bytesize), random.rand(256))
          end
        end
        begin
          result = LicenseExpression.select(bytes, allow_restricted: index.odd?)
          raise 'licence selection has no grant' if result.fetch('grants').empty?
        rescue Error
          # Invalid declarations and disallowed grants are ordinary refusals.
        end
      end
      { 'iterations' => iterations, 'seed' => seed }
    end
  end
end

puts JSON.generate(Erx::LicenseExpressionFuzz.run) if $PROGRAM_NAME == __FILE__
