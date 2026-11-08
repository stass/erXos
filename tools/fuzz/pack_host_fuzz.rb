# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require_relative '../lib/erx/abi'
require_relative '../lib/erx/abi_binary'
require_relative '../lib/erx/elf_plan'
require_relative '../lib/erx/pack_provenance'
require 'tmpdir'
require 'fileutils'

module Erx
  module PackHostFuzz
    module_function

    def run(root:, iterations: 20_000, seed: 1)
      raise Error, 'invalid host fuzz iteration bound' unless iterations.is_a?(Integer) && iterations.between?(1, 1_000_000)
      codec = ABI::Codec.new(ABI::Generator.plan(root: root).schema)
      random = Random.new(seed)
      reply = { 'abi_version' => 1, 'virtual_origin' => 65536, 'fixed_base' => 65536, 'span' => 4096,
                'entry' => 64, 'phdr_offset' => 0, 'output_size' => 8192,
                'flags' => 1, 'phnum' => 1, 'base_alignment' => 4096,
                'loads' => [{ 'source_offset' => 0, 'file_offset' => 4096, 'mem_offset' => 0,
                              'file_size' => 128, 'mem_size' => 128, 'prot' => 5, 'flags' => 0 }] }
      seeds = [JSON.generate(reply).b, "root.o: source.c header.h\n".b,
               "10000 10000 20 4 root.o:(.text)\n".b,
               "Linker script and memory map\n .text 0x10000 0x20 root.o\n".b]
      Dir.mktmpdir('erx-receipt-fuzz-') do |directory|
        receipt, artifact = receipt_seed(directory)
        seeds << JSON.generate(receipt).b
        receipt_path = File.join(directory, 'receipt.json')
        fixed = BuildInputs.pack(root: directory, paths: Dir.children(directory).map { |name| File.join(directory, name) })
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
            when 0
              ElfPlanner.decode(bytes, codec: codec, source_size: 4096, budget: 8192)
            when 1
              PackProvenance.dependencies(bytes)
            when 2
              PackProvenance.contributors(bytes, format: 'lld')
            when 3
              PackProvenance.contributors(bytes, format: 'gnu')
            when 4
              File.binwrite(receipt_path, bytes)
              catalog = fixed.merge(BuildInputs.capture(root: directory, paths: [receipt_path]))
              resolver = PackProvenance.new(root: directory, catalog: catalog)
              resolver.resolve(receipt: receipt_path, artifact: artifact, build_kind: 'development')
            end
          rescue Error
            # Refusal is an ordinary parser result. Any other exception is a bug.
          end
        end
      end
      { 'iterations' => iterations, 'seed' => seed }.freeze
    end

    def receipt_seed(directory)
      files = { 'LICENSE' => 'BSD fixture licence',
                'root.c' => "/* SPDX-License-Identifier: BSD-2-Clause */\n",
                'root.o' => 'object bytes', 'root.elf' => 'artifact bytes',
                'root.d' => "root.o: root.c\n",
                'root.map' => "10000 10000 4 4 root.o:(.text)\n" }
      references = files.to_h do |name, bytes|
        File.binwrite(File.join(directory, name), bytes)
        [name, { 'path' => name, 'sha256' => Digest::SHA256.hexdigest(bytes) }]
      end
      receipt = { 'version' => 1, 'kind' => 'linked', 'artifact' => references.fetch('root.elf'),
                  'linker_map' => references.fetch('root.map').merge('format' => 'lld', 'directory' => '.'),
                  'compiles' => [{ 'object' => references.fetch('root.o'),
                                   'dependency' => references.fetch('root.d'), 'directory' => '.',
                                   'sources' => [references.fetch('root.c')] }],
                  'archives' => [], 'inputs' => [] }
      [receipt, File.join(directory, 'root.elf')]
    end
    private_class_method :receipt_seed
  end
end

if $PROGRAM_NAME == __FILE__
  root = File.expand_path('../..', __dir__)
  puts JSON.generate(Erx::PackHostFuzz.run(root: root))
end
