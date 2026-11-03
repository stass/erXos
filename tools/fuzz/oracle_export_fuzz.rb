# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'tmpdir'
require 'fileutils'
require_relative '../lib/erx/oracle_export'

module Erx
  module OracleExportFuzz
    module_function

    def run(iterations: 20_000, seed: 1)
      raise Error, 'invalid oracle export fuzz bound' unless iterations.is_a?(Integer) && iterations.between?(1, 1_000_000)
      random = Random.new(seed)
      Dir.mktmpdir('oracle-export-fuzz-') do |directory|
        source = File.join(directory, 'source')
        target = File.join(directory, 'artifacts')
        Dir.mkdir(source, 0o700)
        Dir.mkdir(target, 0o700)
        File.open(File.join(source, 'result.json'), 'wb', 0o600) { |file| file.write('{}') }
        OracleExport.call(source: source, destination: target, operation: 'probe')
        path = File.join(target, 'export.json')
        original = File.binread(path)
        iterations.times do
          bytes = original.dup
          random.rand(1..8).times do
            if random.rand(4).zero?
              bytes = bytes.byteslice(0, random.rand(0..bytes.bytesize))
            elsif !bytes.empty?
              bytes.setbyte(random.rand(bytes.bytesize), random.rand(256))
            end
          end
          File.binwrite(path, bytes)
          begin
            OracleExport.verify(destination: target)
          rescue Error
            # Invalid inventories are ordinary refusals; other errors are bugs.
          end
        end
      end
      { 'iterations' => iterations, 'seed' => seed }.freeze
    end
  end
end

puts JSON.generate(Erx::OracleExportFuzz.run) if $PROGRAM_NAME == __FILE__
