#!/usr/bin/env ruby
# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'json'
require 'optparse'
require_relative '../../tools/lib/erx/abi'
require_relative '../../tools/lib/erx/abi_binary'
require_relative '../../tools/lib/erx/manifest'
require_relative '../fixtures/abi_manifest_fixture'
require_relative '../fixtures/manifest_context'

# Deterministic mutations enter production parsers. Only domain errors count
# as refusals; a Ruby exception or failed invariant terminates the target.
module AbiFuzz
  module_function

  def mutate(bytes, random)
    changed = bytes.dup
    case random.rand(4)
    when 0
      changed = changed.byteslice(0, random.rand(changed.bytesize + 1))
    when 1
      changed.insert(random.rand(changed.bytesize + 1), random.bytes(random.rand(1..32)))
    when 2
      unless changed.empty?
        random.rand(1..8).times { changed.setbyte(random.rand(changed.bytesize), random.rand(256)) }
      end
    when 3
      changed = random.bytes(random.rand(4097))
    end
    changed
  end

  def run(root:, seconds:, seed:)
    source = Erx::ABI::Sources.read(root: root)
    schema = Erx::ABI::Model.validate(source)
    codec = Erx::ABI::Codec.new(schema)
    context = Erx::Manifest::Context.new(**ManifestContextFixture.arguments(codec))
    declaration_seed = source.inputs.values.join("\n").gsub(/^include .*\n/, '')
    manifest_seed = File.binread(File.join(root, 'test/fixtures/manifest_empty.txt'))
    wire_seeds = [AbiManifestFixture.valid, AbiManifestFixture.unit_partition,
                  AbiManifestFixture.unit_partition(overlap: true),
                  AbiManifestFixture.facet_parameter, AbiManifestFixture.session_template]
    random = Random.new(seed)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + seconds
    count = 0
    top = File.expand_path('../..', __dir__)
    system_seed = File.binread(File.join(top, 'config/manifest/qemu-virt-development.txt'))
    system_platform = JSON.parse(File.read(File.join(top, 'config/platforms/qemu-virt.json')))
    system_context = Erx::Manifest::Context.new(**ManifestContextFixture.arguments(codec).merge(platform: system_platform))
    domain_seed = ManifestContextFixture.domain_source(system_seed)
    domain_context = Erx::Manifest::Context.new(**ManifestContextFixture.domain_arguments(codec).merge(platform: system_platform))
    until Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
      begin
        case count % 5
        when 0
          declarations = Erx::ABI::Syntax.parse(mutate(declaration_seed, random))
          parsed = Erx::ABI::SourceSet.new(declarations: declarations, inputs: {}).freeze
          Erx::ABI::Model.validate(parsed)
        when 1
          Erx::Manifest.structural_fixture(source: mutate(manifest_seed, random), codec: codec, context: context)
        when 2
          view = codec.open('manifest', mutate(wire_seeds.fetch(random.rand(wire_seeds.size)), random))
          schema.readers.find { |reader| reader.name == 'manifest' }.tables.each_key do |table|
            view.each(table) { |_record| }
          end
        when 3
          Erx::Manifest.admit(source: mutate(system_seed, random), codec: codec, context: system_context,
                              planner: ManifestContextFixture.accepting_planner)
        when 4
          Erx::Manifest.admit(source: mutate(domain_seed, random), codec: codec, context: domain_context,
                              planner: ManifestContextFixture.accepting_planner)
        end
      rescue Erx::Error
        # A bounded, typed diagnostic is a valid parser result.
      end
      count += 1
    end
    count
  end
end

if $PROGRAM_NAME == __FILE__
  options = { seconds: 5, seed: 0x455258 }
  parser = OptionParser.new do |arguments|
    arguments.on('--seconds N', Integer) { |value| options[:seconds] = value }
    arguments.on('--seed N', Integer) { |value| options[:seed] = value }
  end
  begin
    remaining = parser.parse(ARGV)
    unless remaining.empty? && options[:seconds].between?(1, 3600) && options[:seed].between?(0, (1 << 64) - 1)
      raise OptionParser::InvalidArgument, 'seconds, seed or trailing arguments outside bounds'
    end
    count = AbiFuzz.run(root: File.expand_path('../..', __dir__), **options)
    Erx::Terminal.puts("ABI and manifest Ruby fuzz passed: #{count} inputs, seed #{options[:seed]}")
  rescue OptionParser::ParseError => error
    Erx::Terminal.puts(error.message)
    exit 2
  end
end
