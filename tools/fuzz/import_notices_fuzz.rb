# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require_relative '../lib/erx/import_notices'

module Erx
  module ImportNoticesFuzz
    module_function

    def run(iterations: 20_000, seed: 1)
      raise Error, 'invalid notice-profile fuzz bound' unless iterations.is_a?(Integer) && iterations.between?(1, 1_000_000)
      random = Random.new(seed)
      fixture = JSON.generate('version' => 1, 'licenses' => {
        'MIT' => [{ 'path' => 'package/COPYRIGHT', 'sha256' => 'a' * 64 }] },
        'packages' => [{ 'path' => 'package/nested', 'notices' => [], 'grants' => {
          'BSD-3-Clause' => [{ 'path' => 'package/nested/LICENSE', 'sha256' => 'b' * 64 }] } }]).b
      iterations.times do
        bytes = fixture.dup
        random.rand(1..8).times do
          if random.rand(4).zero?
            bytes = bytes.byteslice(0, random.rand(0..bytes.bytesize))
          elsif !bytes.empty?
            bytes.setbyte(random.rand(bytes.bytesize), random.rand(256))
          end
        end
        begin
          profile = ImportNotices.parse(bytes)
          ImportNotices.select(profile, source: 'package/nested/code.c', grants: ['BSD-3-Clause'])
        rescue Error
          # Malformed declarations are ordinary refusals; other errors are bugs.
        end
      end
      { 'iterations' => iterations, 'seed' => seed }
    end
  end
end

puts JSON.generate(Erx::ImportNoticesFuzz.run) if $PROGRAM_NAME == __FILE__
