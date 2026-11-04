# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'digest'
require 'fileutils'
require 'tmpdir'
require_relative 'abi'
require_relative 'boot_file'
require_relative 'fiasco'
require_relative 'output_directory'
require_relative 'pack_tools'
require_relative 'toolchain_provenance'
require_relative '../../../test/fixtures/structural_pack'

module Erx
  # A bootable file for the stopgap from what the build holds: bootstrap as the
  # first stage and an archive of the kernel, sigma0 and, for a guest test, a
  # root task that bootstrap places. The archive is the structural recipe's,
  # never admitted: production packing waits for the root startup, so its
  # manifest and its own root entry say nothing about what runs.
  class BootImage
    Built = Data.define(:single, :archive, :first_stage, :index_hash, :build_id, :flags) do
      def fetch(name) = public_send(name)
    end

    # kernel replaces the built kernel, for a suite that boots a test kernel.
    def initialize(root:, runner:, compiler:, linker:, kernel: nil)
      @root = File.expand_path(root)
      @runner = runner
      @compiler = compiler
      @linker = linker
      @codec = ABI::Codec.new(ABI::Generator.plan(root: @root).schema)
      @fiasco = Fiasco.new(root: @root, runner: runner, compiler: compiler)
      @kernel = kernel || @fiasco.kernel_path
    end

    # Rebuilds directory from nothing, so a stale archive cannot stand in.
    def build(directory:, stand_in_root: nil)
      FileUtils.remove_entry(directory) if File.exist?(directory)
      OutputDirectory.prepare(root: @root, path: directory)
      recipe = File.join(directory, 'recipe')
      fixture = StructuralPackFixture.build(root: @root, directory: recipe, codec: @codec, runner: @runner, tools: tools,
                                            compiler: @compiler, linker: @linker, external: external,
                                            extra_files: extra_files(stand_in_root), first_stage: @fiasco.image_path)
      report = fixture.fetch('report')
      header = @codec.decode_layout('erx_pack_header', File.binread(report.fetch('path'), @codec.layout_size('erx_pack_header')))
      Built.new(single: report.fetch('single_path'), archive: report.fetch('path'), first_stage: @fiasco.image_path,
                index_hash: header.fetch('index_hash').unpack1('H*'),
                build_id: header.fetch('build_id').unpack1('H*'), flags: header.fetch('flags'))
    end

    # The packer's BLAKE3 of a byte string.
    def digest(bytes)
      Dir.mktmpdir('erx-boot-image-') do |directory|
        input = File.join(directory, 'input')
        File.binwrite(input, bytes)
        PackHasher.new(helper: tools.fetch('hasher'), runner: @runner).digests(input, [[0, bytes.bytesize]]).first
      end
    end

    private

    def extra_files(stand_in_root)
      files = [{ path: @codec.fixed_bytes('boot_kernel_path'), snapshot: @kernel },
               { path: @codec.fixed_bytes('boot_sigma0_path'), snapshot: @fiasco.sigma0_path }]
      files << { path: @codec.fixed_bytes('boot_stand_in_root_path'), snapshot: stand_in_root } if stand_in_root
      files.each { |file| raise Error, "#{file.fetch(:snapshot)} is not built" unless File.file?(file.fetch(:snapshot)) }
      files
    end

    def tools
      @tools ||= PackTools.build(root: @root, owner_root: @root, directory: File.join(@root, 'build/boot-image-tools'),
                                 runner: @runner, compiler: @compiler, sanitizers: [])
    end

    def external
      resource = @runner.run([@compiler, '-print-resource-dir'], name: 'clang-resource-directory', deadline: 30)
      installation = File.expand_path('../../..', File.read(resource.fetch('log')).strip)
      ToolchainProvenance.registry(profile: File.join(@root, 'config/provenance/llvm-23.1.3.json'),
                                   installation: installation)
    end
  end
end
