# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'digest'
require 'fileutils'
require 'json'
require 'open3'
require_relative 'abi'
require_relative 'build_inputs'
require_relative 'error'
require_relative 'json_input'
require_relative 'manifest'
require_relative 'oracle'
require_relative 'output_directory'
require_relative 'pack'
require_relative 'pack_provenance'
require_relative 'pack_tools'
require_relative 'runner'
require_relative 'runtime'
require_relative 'toolchain_provenance'
require_relative '../../../test/fixtures/pack_root'

module Erx
  # The system release: `kernel` and `stdlib`'s beams and application files with a
  # start.boot of their own, as docs/design-runtime.md's Configuration starts them. It
  # goes through Pack#build with the development manifest, so hosted and native run
  # the same files; only the root differs. Hosted, the root is a minimal static
  # executable that never runs, since erx_pack_open and the packer require one
  # (docs/design-stopgap.md, "The archive has a root that never runs").
  class Release
    APPLICATIONS = %w[kernel stdlib].freeze
    NAME = 'erxos'
    MANIFEST = 'config/manifest/qemu-virt-development.txt'
    PLATFORM = 'config/platforms/qemu-virt.json'
    TOOLCHAIN_PROFILE = 'config/provenance/llvm-23.1.3.json'
    BOOT_DEADLINE = 120
    # What an archive names by itself rather than by the release: the root and these
    # two say what each build links, so a comparison of two archives leaves them out.
    NOT_RELEASE_FILES = %w[system/root system/manifest system/NOTICES].freeze
    # A file of the release: its path in the archive, the built file and what it came from.
    ReleaseFile = Data.define(:path, :artifact, :sources)

    # The archive's release files as [path, content hash], sorted, from its index alone.
    def self.file_table(archive:, codec:)
      rows = entries_of(File.binread(archive), codec).map { |path, entry| [path, entry.fetch('file_hash').unpack1('H*')] }
      rows.reject { |path, _hash| NOT_RELEASE_FILES.include?(path) }.sort.freeze
    end

    # The bytes of one file of an archive, found through its index.
    def self.file_bytes(archive:, path:, codec:)
      bytes = File.binread(archive)
      entries_of(bytes, codec).each do |name, entry|
        return bytes.byteslice(entry.fetch('data_off'), entry.fetch('data_size')) if name == path
      end
      raise Error, "#{archive} holds no #{path}"
    end

    # Each file of an archive as [path, entry], in the index's order.
    def self.entries_of(bytes, codec)
      header = codec.decode_layout('erx_pack_header', bytes)
      strings = bytes.byteslice(header.fetch('strings_off'), header.fetch('strings_size'))
      Array.new(header.fetch('nentries')) do |index|
        at = header.fetch('entries_off') + index * header.fetch('entry_size')
        entry = codec.decode_layout('erx_pack_entry', bytes.byteslice(at, header.fetch('entry_size')))
        [strings.byteslice(entry.fetch('path_off'), entry.fetch('path_len')), entry]
      end
    end
    private_class_method :entries_of

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
      files = [*application_files, boot_file]
      tools = PackTools.build(root: @root, owner_root: @root, directory: File.join(@directory, 'tools'),
                              runner: @runner, compiler: @compiler, sanitizers: [])
      root_task = PackRootFixture.build(root: @root, directory: File.join(@directory, 'root'), codec: @codec,
                                        runner: @runner, compiler: @compiler, linker: @linker)
      entries = [root_entry(root_task), *files.map { |file| file_entry(file) }]
      catalog = root_task.fetch('catalog').merge(BuildInputs.pack(root: @root, paths: inputs_of(entries.drop(1))))
      pack_with(tools, catalog).build(
        entries: entries, root_path: 'system/root', build_kind: 'development',
        platform: JsonInput.parse(File.binread(File.join(@root, PLATFORM)), max_bytes: 1024 * 1024, label: 'platform record'),
        artifacts: { 'root' => { 'kind' => 'executable', 'entry' => root_index(entries) } },
        manifest_source: File.binread(File.join(@root, MANIFEST)), output: output
      )
    end

    private

    def application_files
      APPLICATIONS.flat_map do |application|
        ebin = File.join(@otp, 'lib', application, 'ebin')
        directory = "system/lib/#{application}-#{version(application)}/ebin"
        Dir.glob('*.{beam,app}', base: ebin).sort.map do |name|
          ReleaseFile.new(path: "#{directory}/#{name}", artifact: File.join(ebin, name), sources: sources_of(application, name))
        end
      end
    end

    # The source a built file is compiled from. A file with none named is a failure, so
    # no file reaches the archive without its licence.
    def sources_of(application, name)
      source = File.join(@root, 'otp/lib', application, 'src')
      base = File.basename(name, '.*')
      return [File.join(source, "#{base}.app.src")] if name.end_with?('.app')

      found = %w[erl yrl xrl].map { |extension| File.join(source, "#{base}.#{extension}") }.find { |path| File.file?(path) } ||
              Dir.glob(File.join(@root, 'otp/lib', application, '**', "#{base}.erl")).min
      raise Error, "no source in otp/lib/#{application} for #{name}" unless found

      [found]
    end

    def version(application)
      text = File.read(File.join(@otp, 'lib', application, 'ebin', "#{application}.app"))
      text[/\{vsn,\s*"([^"]+)"\}/, 1] or raise Error, "#{application}.app names no version"
    end

    def erts_version
      File.read(File.join(@otp, 'erts/vsn.mk'))[/^VSN\s*=\s*(\S+)/, 1] or raise Error, 'erts/vsn.mk names no version'
    end

    # OTP's own generator: systools on the stock host build of the same release, which
    # writes the boot script from the release file and the applications' own .app files.
    def boot_file
      release = File.join(@directory, 'start.rel')
      applications = APPLICATIONS.map { |application| "{#{application},\"#{version(application)}\"}" }.join(',')
      File.write(release, "{release,{\"#{NAME}\",\"1\"},{erts,\"#{erts_version}\"},[#{applications}]}.\n")
      paths = APPLICATIONS.map { |application| "\"#{File.join(@otp, 'lib', application, 'ebin')}\"" }.join(',')
      name = File.join(@directory, 'start')
      expression = "ok=systools:make_script(\"#{name}\",[{path,[#{paths}]},no_dot_erlang,no_warn_sasl]),halt()."
      @runner.run([@oracle.erl_path(Runtime::HOST_OTP_FLAVOUR), '-noshell', '-noinput', '-eval', expression],
                  name: 'release-boot-script', deadline: BOOT_DEADLINE, chdir: @directory, env: Oracle::CLEAN_ERLANG_ENV)
      ReleaseFile.new(path: 'system/bin/start.boot', artifact: "#{name}.boot",
                sources: APPLICATIONS.map { |application| File.join(@root, 'otp/lib', application, 'src', "#{application}.app.src") })
    end

    def file_entry(file)
      receipt = File.join(@directory, 'receipts', "#{file.path.tr('/', '_')}.json")
      FileUtils.mkdir_p(File.dirname(receipt))
      File.write(receipt, JSON.pretty_generate('version' => 1, 'kind' => 'compiled', 'artifact' => reference(file.artifact),
                                               'sources' => file.sources.map { |source| reference(source) }))
      { 'path' => file.path, 'kind' => @codec.member('entry_kind', 'file'), 'flags' => @codec.member('entry_flags', 'system'),
        'id' => file.path, 'artifact' => file.artifact, 'receipt' => receipt }
    end

    def root_entry(root_task)
      { 'path' => 'system/root', 'kind' => @codec.member('entry_kind', 'image'), 'flags' => @codec.member('entry_flags', 'system'),
        'id' => 'root', 'artifact' => root_task.fetch('artifact'), 'receipt' => root_task.fetch('receipt') }
    end

    # The root's place in the index, whose order takes in the two files the pack adds.
    def root_index(entries)
      generated = [@codec.fixed_bytes('system_manifest_path'), 'system/NOTICES']
      [*entries.map { |entry| entry.fetch('path') }, *generated].map(&:b).sort.index('system/root')
    end

    def inputs_of(entries)
      entries.flat_map { |entry| [entry.fetch('artifact'), entry.fetch('receipt')] }
    end

    def pack_with(tools, catalog)
      Pack.new(root: @root, output_root: @root, codec: @codec, runner: @runner,
               planner: ElfPlanner.new(helper: tools.fetch('planner'), runner: @runner, codec: @codec),
               checker: tools.fetch('checker'), hasher: tools.fetch('hasher'),
               provenance: PackProvenance.new(root: @root, catalog: catalog, external: toolchain, runner: @runner,
                                              imports: { File.join(@root, 'otp') => 'permanent' }))
    end

    def toolchain
      resource = @runner.run([@compiler, '-print-resource-dir'], name: 'clang-resource-directory', deadline: 30)
      installation = File.expand_path('../../..', File.read(resource.fetch('log')).strip)
      ToolchainProvenance.registry(profile: File.join(@root, TOOLCHAIN_PROFILE), installation: installation)
    end

    def reference(path)
      { 'path' => path.delete_prefix("#{@root}/"), 'sha256' => Digest::SHA256.file(path).hexdigest }
    end
  end
end
