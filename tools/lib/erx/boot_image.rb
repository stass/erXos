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
require_relative 'platform'
require_relative 'production_image'
require_relative 'toolchain_provenance'
require_relative 'structural_pack'

module Erx
  # A bootable file for Fiasco from what the build holds: platform's first stage
  # (Fiasco#first_stage_path), bootstrap, and an archive of the kernel, sigma0 and, for a
  # guest test, a root task that bootstrap places, checked against platform's RAM and
  # loader as the production image's is. The archive is the structural recipe's:
  # its empty manifest passes the manifest check like any other, but it and
  # the archive's own root entry say nothing about what runs.
  class BootImage
    Built = Data.define(:single, :archive, :first_stage, :index_hash, :build_id, :flags) do
      def fetch(name) = public_send(name)
    end

    # kernel replaces the built kernel, for a suite that boots a test kernel; platform is
    # the board the file boots on, QEMU virt's development platform unless given.
    def initialize(root:, runner:, compiler:, linker:, kernel: nil, platform: Platform.development(root))
      @root = File.expand_path(root)
      @runner = runner
      @compiler = compiler
      @linker = linker
      @codec = ABI::Codec.new(ABI::Generator.plan(root: @root).schema)
      @fiasco = Fiasco.new(root: @root, runner: runner, compiler: compiler)
      @kernel = kernel || @fiasco.kernel_path
      @platform = platform
    end

    # Rebuilds directory from nothing, so a stale archive cannot stand in. programs maps
    # further archive paths to files, which a stand-in root loads; images maps paths to
    # executables packed as image entries, as a domain runtime is, and jit names those of
    # them whose manifest marks ERX_IMAGE_JIT, as the BeamAsm runtime's does.
    def build(directory:, stand_in_root: nil, programs: {}, images: {}, jit: [])
      OutputDirectory.fresh(root: @root, path: directory)
      recipe = File.join(directory, 'recipe')
      fixture = StructuralPack.build(root: @root, directory: recipe, codec: @codec, runner: @runner, tools: tools,
                                     compiler: @compiler, linker: @linker, external: external,
                                     extra_files: extra_files(stand_in_root, programs, images, jit), first_stage: first_stage)
      report = fixture.fetch('report')
      ProductionImage::Machine.development(@platform)
                              .check_single_file(File.size(report.fetch('single_path')), load_address: @fiasco.first_stage_address(@platform))
      header = @codec.decode_layout('erx_pack_header', File.binread(report.fetch('path'), @codec.layout_size('erx_pack_header')))
      Built.new(single: report.fetch('single_path'), archive: report.fetch('path'), first_stage: first_stage,
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

    def first_stage = @fiasco.first_stage_path(@platform)

    def extra_files(stand_in_root, programs, images, jit)
      stray = jit - images.keys
      raise Error, "jit names #{stray.join(', ')}, which images does not pack" unless stray.empty?

      files =[{ path: @codec.fixed_bytes('boot_kernel_path'), snapshot: @kernel },
               { path: @codec.fixed_bytes('boot_sigma0_path'), snapshot: @fiasco.sigma0_path }]
      files << { path: @codec.fixed_bytes('boot_stand_in_root_path'), snapshot: stand_in_root } if stand_in_root
      files.concat(programs.map { |path, file| { path: path, snapshot: file } })
      files.concat(images.map { |path, file| { path: path, snapshot: file, image: true, jit: jit.include?(path) } })
      files.each { |file| raise Error, "#{file.fetch(:snapshot)} is not built" unless File.file?(file.fetch(:snapshot)) }
      files
    end

    def tools
      @tools ||= PackTools.build(root: @root, owner_root: @root, directory: File.join(@root, 'build/boot-image-tools'),
                                 runner: @runner, compiler: @compiler, sanitizers: [])
    end

    def external
      resource = @runner.run([@compiler, '-print-resource-dir'], name: 'clang-resource-directory', deadline: 30)
      ToolchainProvenance.llvm(root: @root, resource_dir: File.read(resource.fetch('log')).strip)
    end
  end
end
