# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'digest'
require 'fileutils'
require 'json'
require 'open3'
require_relative 'abi'
require_relative 'dom_planner'
require_relative 'build_inputs'
require_relative 'error'
require_relative 'json_input'
require_relative 'manifest'
require_relative 'oracle'
require_relative 'output_directory'
require_relative 'pack'
require_relative 'pack_provenance'
require_relative 'pack_tools'
require_relative 'pack_wire'
require_relative 'production_image'
require_relative 'release_files'
require_relative 'release_medium'
require_relative 'runner'
require_relative 'runtime'
require_relative 'toolchain_provenance'
require_relative '../../../test/fixtures/pack_root'

module Erx
  # The system release as an archive of its own: ReleaseFiles through Pack#build with the
  # development manifest, so hosted and native run the same files; only the root differs.
  # Hosted, the root is a minimal static executable that never runs, since erx_pack_open
  # and the packer require one (docs/design-stopgap.md, "The archive has a root that
  # never runs").
  class Release
    MANIFEST = 'config/manifest/qemu-virt-development.txt'
    PLATFORM = 'config/platforms/qemu-virt.json'
    # What an archive names by itself rather than by the release: the root and these
    # two say what each build links, so a comparison of two archives leaves them out,
    # as it leaves out the build facts at the ABI's build_facts_path, which say which
    # build an image is and which only the production image carries.
    NOT_RELEASE_FILES = %w[system/root system/manifest system/NOTICES].freeze

    # The archive's release files as [path, content hash], sorted, from its index alone.
    def self.file_table(archive:, codec:)
      rows = PackWire.entries_of(File.binread(archive), codec).map { |path, entry| [path, entry.fetch('file_hash').unpack1('H*')] }
      excluded = [*NOT_RELEASE_FILES, codec.fixed_bytes('build_facts_path')]
      rows.select { |path, _hash| path.start_with?('system/') && !excluded.include?(path) }.sort.freeze
    end

    # The bytes of one file of an archive, found through its index.
    def self.file_bytes(archive:, path:, codec:)
      bytes = File.binread(archive)
      PackWire.entries_of(bytes, codec).each do |name, entry|
        return bytes.byteslice(entry.fetch('data_off'), entry.fetch('data_size')) if name == path
      end
      raise Error, "#{archive} holds no #{path}"
    end

    # What one table has and the other does not, as [path, hash] rows: empty when the
    # two archives hold the same release.
    def self.differences(left, right) = ((left - right) | (right - left)).sort

    def initialize(root:, output:, runner: nil, oracle: nil, compiler: ENV.fetch('ERX_CLANG', 'clang'),
                   linker: ENV.fetch('ERX_LLD', 'ld.lld'))
      @root = File.realpath(root)
      @otp = output.root
      @archive = output.archive
      @directory = File.join(File.dirname(@archive), 'work')
      @runner = runner || Runner.new(owner_root: @root, log_dir: File.join(@root, 'build/logs'))
      @oracle = oracle || Oracle.new(root: @root, runner: @runner)
      @compiler = compiler
      @linker = linker
      @codec = ABI::Codec.new(ABI::Generator.plan(root: @root).schema)
    end

    # Packs the release into output, replacing what a failed run cannot leave behind.
    def build(output: @archive)
      FileUtils.rm_f(output)
      FileUtils.rm_rf(@directory)
      FileUtils.mkdir_p(@directory)
      OutputDirectory.prepare(root: @root, path: @directory)
      tools = PackTools.build(root: @root, owner_root: @root, directory: File.join(@directory, 'tools'),
                              runner: @runner, compiler: @compiler, sanitizers: [])
      root_task = PackRootFixture.build(root: @root, directory: File.join(@directory, 'root'), codec: @codec,
                                        runner: @runner, compiler: @compiler, linker: @linker)
      files = ReleaseFiles.new(root: @root, otp: @otp, directory: @directory, runner: @runner, codec: @codec, oracle: @oracle).entries
      manifest_source = File.binread(File.join(@root, MANIFEST))
      domains = domain_entries(manifest_source, root_task)
      entries = [root_entry(root_task), *files, *domains]
      _erofs, images = ReleaseMedium.image(entries: files, directory: @directory, runner: @runner)
      catalog = root_task.fetch('catalog').merge(BuildInputs.pack(root: @root, paths: ReleaseFiles.inputs_of([*files, *domains], root: @root)))
      pack_with(tools, catalog).build(
        entries: entries, root_path: 'system/root', build_kind: 'development',
        platform: JsonInput.parse(File.binread(File.join(@root, PLATFORM)), max_bytes: 1024 * 1024, label: 'platform record'),
        artifacts: ProductionImage.artifacts(archive_paths(entries), images: images),
        manifest_source: manifest_source, output: output
      )
    end

    private

    def root_entry(root_task)
      { 'path' => 'system/root', 'kind' => @codec.member('entry_kind', 'image'), 'flags' => @codec.member('entry_flags', 'system'),
        'id' => 'root', 'artifact' => root_task.fetch('artifact'), 'receipt' => root_task.fetch('receipt') }
    end

    # The domain release, with a boot script for each name the manifest's session and
    # domain rows give their release, under domains/ as the production image carries it.
    # Two stand-ins take the runtime images' places: the root-task fixture's program at
    # ProductionImage::DOMAIN_RUNTIME_PATH, and again at JIT_RUNTIME_PATH, marked jit as
    # ProductionImage#domain_parts marks the BeamAsm image. They exist only so the manifest's
    # @artifact.emu and @artifact.jit resolve here as natively. None runs: hosted,
    # erx_domain_lib does not load, so the domain service makes no domain and starts no session.
    def domain_entries(manifest_source, root_task)
      boots = Manifest.release_names(source: manifest_source, codec: @codec).map { |name| ProductionImage.domain_boot(name) }
      return [] if boots.empty?

      stand_in = { 'kind' => @codec.member('entry_kind', 'image'), 'flags' => 0,
                   'artifact' => root_task.fetch('artifact'), 'receipt' => root_task.fetch('receipt') }
      runtimes = [stand_in.merge('path' => ProductionImage::DOMAIN_RUNTIME_PATH, 'id' => 'domain-runtime'),
                  stand_in.merge('path' => ProductionImage::JIT_RUNTIME_PATH, 'id' => 'jit-runtime', 'jit' => true)]
      [*runtimes, *ReleaseFiles.new(root: @root, otp: @otp, directory: File.join(@directory, 'domains'), runner: @runner,
                                    codec: @codec, oracle: @oracle, release: ReleaseFiles.domain(boots)).entries]
    end

    # The archive's sorted paths, which take in the two files the pack adds, and by
    # which ProductionImage.artifacts names the root, the runtime and each release.
    def archive_paths(entries)
      generated = [@codec.fixed_bytes('system_manifest_path'), 'system/NOTICES']
      [*entries.map { |entry| entry.fetch('path') }, *generated].map(&:b).sort
    end

    def pack_with(tools, catalog)
      Pack.new(root: @root, output_root: @root, codec: @codec, runner: @runner,
               planner: ElfPlanner.new(helper: tools.fetch('planner'), runner: @runner, codec: @codec),
               checker: tools.fetch('checker'), hasher: tools.fetch('hasher'),
               domain_planner: DomainPlanner.new(helper: tools.fetch('domains'), runner: @runner),
               provenance: PackProvenance.new(root: @root, catalog: catalog, external: toolchain, runner: @runner,
                                              imports: { File.join(@root, 'otp') => 'permanent' }))
    end

    def toolchain
      resource = @runner.run([@compiler, '-print-resource-dir'], name: 'clang-resource-directory', deadline: 30)
      ToolchainProvenance.llvm(root: @root, resource_dir: File.read(resource.fetch('log')).strip)
    end
  end
end
