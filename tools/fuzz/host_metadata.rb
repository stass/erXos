#!/usr/bin/env ruby
# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'optparse'
require 'tmpdir'
require_relative '../lib/erx/tla'
require_relative '../lib/erx/origin'
require_relative '../lib/erx/hardware'
require_relative '../lib/erx/toolchain_provenance'
require_relative '../lib/erx/arch_terms'
require_relative '../lib/erx/sysreg'
require_relative '../../test/fixtures/sysreg_fixture'

module Erx
  module HostMetadataFuzz
    TARGETS = %w[tlc roster origin attribution dependencies svd toolchain arch_terms sysreg_specification sysreg_source].freeze
    module_function

    def mutate(bytes, random:)
      result = bytes.b.dup
      case random.rand(3)
      when 0
        result.setbyte(random.rand(result.bytesize), random.rand(256)) unless result.empty?
      when 1
        result.insert(random.rand(result.bytesize + 1), random.bytes(random.rand(1..16)))
      when 2
        result.slice!(random.rand(result.bytesize), random.rand(1..16)) unless result.empty?
      end
      result
    end

    def seeds
      entry = { 'id' => 'smoke', 'module' => 'Smoke', 'config' => 'Smoke.cfg',
                'translation' => 'tla', 'deadline' => 10, 'deadlock' => 'check',
                'scope' => 'finite', 'expect' => { 'kind' => 'pass' } }
      origin = { 'version' => 1, 'repository' => 'https://example.org/source', 'revision' => '1',
                 'archive_sha256' => 'a' * 64, 'exclusions' => [], 'files' => {}, 'changes' => {} }
      source = { 'id' => 'fixture', 'kind' => 'file', 'version' => '1',
                 'url' => 'https://example.org/tool.jar', 'sha256' => 'a' * 64,
                 'filename' => 'tool.jar', 'license' => 'MIT', 'status' => 'permanent' }
      toolchain = { 'version' => 1, 'label' => 'fixture', 'license' => 'MIT', 'status' => 'permanent',
                    'evidence' => 'reviewed fuzz fixture',
                    'files' => ['header.h'], 'notices' => ['LICENSE'] }
      { 'tlc' => "@!@!@STARTMSG 2110:1 @!@!@\nInvariant Bounded is violated.\n@!@!@ENDMSG 2110 @!@!@\n",
        'roster' => JSON.generate('version' => 1, 'entries' => [entry]),
        'origin' => JSON.generate(origin), 'attribution' => "/* SPDX-License-Identifier: MIT OR BSD-2-Clause */\n",
        'dependencies' => JSON.generate('version' => 1, 'sources' => [source]),
        'svd' => File.binread(File.expand_path('../../hw/svd/virtio_mmio/virtio_mmio.svd', __dir__)),
        'toolchain' => JSON.generate(toolchain), 'arch_terms' => "word EL1\nprefix ICC_\n",
        'sysreg_specification' => File.binread(File.expand_path('../../hw/sysreg/aarch64.json', __dir__)),
        'sysreg_source' => JSON.generate([SysregFixture.record]) }.freeze
    end

    def exercise(target, bytes:, root:)
      case target
      when 'tlc'
        TlcOutput.parse(bytes)
        TlcOutput.classify(bytes, command: { 'state' => 'failed', 'exit_status' => 12 },
                          expectation: { 'kind' => 'counterexample', 'property' => 'Bounded', 'exit_status' => 12 })
      when 'roster'
        TlaRoster.parse(bytes, inputs: { 'Smoke.tla' => '---- MODULE Smoke ---- ====',
                                        'Smoke.cfg' => "SPECIFICATION Spec\n" })
      when 'origin'
        File.binwrite(File.join(root, 'ORIGIN.md'), "# Fixture\n\n```json\n".b + bytes + "\n```\n".b)
        Origin.new(root: root).check
      when 'attribution'
        Attribution.for_file('fixture.c', bytes: bytes, sidecar: nil,
                             review: { 'rules' => [], 'default_license' => 'MIT',
                                       'default_evidence' => 'reviewed fuzz fixture' })
      when 'dependencies'
        DependencySchema.parse(bytes)
      when 'svd'
        Hardware.parse_peripherals(bytes).map { |device| Hardware.device_header(device) }
      when 'toolchain'
        File.binwrite(File.join(root, 'profile.json'), bytes)
        ToolchainProvenance.registry(profile: File.join(root, 'profile.json'), installation: root)
      when 'arch_terms'
        ArchTerms.parse(bytes)
      when 'sysreg_specification'
        # Both readers of the file; each must refuse through the error boundary.
        %i[specification selection].each do |reader|
          Sysreg.public_send(reader, bytes)
        rescue Error
          nil
        end
      when 'sysreg_source'
        declaration = Sysreg.selection(JSON.generate(SysregFixture.specification(bytes)))
        Sysreg.extract(bytes, declaration: declaration)
      end
    rescue Error
      # Invalid inputs must be rejected through the domain error boundary.
      nil
    end

    def run(arguments)
      target = nil
      seconds = 3
      seed = 1
      parser = OptionParser.new do |options|
        options.on('--target NAME', TARGETS, 'Parser to exercise') { |value| target = value }
        options.on('--seconds N', Integer, 'Hard outer caller deadline is also required') { |value| seconds = value }
        options.on('--seed N', Integer, 'Reproducible mutation seed') { |value| seed = value }
      end
      parser.parse!(arguments)
      unless arguments.empty? && TARGETS.include?(target) && seconds.between?(1, 60)
        raise OptionParser::InvalidArgument, 'select a target and a budget of 1..60 seconds'
      end
      random = Random.new(seed)
      initial = seeds.fetch(target)
      count = 0
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + seconds
      Dir.mktmpdir('erx-metadata-fuzz-') do |root|
        if target == 'toolchain'
          File.binwrite(File.join(root, 'header.h'), "/* SPDX-License-Identifier: MIT */\n")
          File.binwrite(File.join(root, 'LICENSE'), 'fixture')
        end
        until Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
          bytes = mutate(initial, random: random)
          exercise(target, bytes: bytes, root: root)
          count += 1
        end
      end
      Terminal.puts("#{target}: #{count} cases, seed #{seed}, budget #{seconds}s")
      0
    rescue OptionParser::ParseError => error
      Terminal.puts(error.message)
      2
    end
  end
end

exit(Erx::HostMetadataFuzz.run(ARGV)) if $PROGRAM_NAME == __FILE__
