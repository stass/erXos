# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'digest'
require 'fileutils'
require 'json'
require_relative 'abi'
require_relative 'boot_file'
require_relative 'build_inputs'
require_relative 'error'
require_relative 'fiasco'
require_relative 'fiasco_provenance'
require_relative 'json_input'
require_relative 'manifest'
require_relative 'native_root'
require_relative 'output_directory'
require_relative 'pack'
require_relative 'pack_provenance'
require_relative 'pack_tools'
require_relative 'qemu'
require_relative 'runner'

module Erx
  # The image the system boots from: bootstrap as the first stage, and an archive that
  # Pack's one funnel builds and Phase 1's manifest check admits (docs/design-stopgap.md,
  # "The Phase 1 manifest check"). Test images come from BootImage instead, whose
  # structural recipe lives under test/fixtures; nothing here reaches that recipe.
  class ProductionImage
    PLATFORM = 'config/platforms/qemu-virt.json'
    MANIFEST = 'config/manifest/qemu-virt-development.txt'
    ROOT_ENTRY_PATH = 'system/root'
    NOTICES_PATH = 'system/NOTICES'
    MEMORY_MIB = 512
    # Below root_memory on QEMU virt, so the root must refuse the boot.
    TOO_LITTLE_MEMORY_MIB = 256
    LICENSE = 'LICENSE'

    # One of Fiasco's archives that the root links, attributed whole under the license
    # stated here. TODO.md holds the gap: the boot cores hold BLAKE3 as well.
    Archive = Data.define(:path, :label, :license, :status, :notice)

    Built = Data.define(:single, :archive, :first_stage, :index_hash, :build_id, :report)

    def initialize(root:, runner:, compiler:, linker:, fiasco: Fiasco.new(root: root, runner: runner, compiler: compiler))
      @root = File.realpath(root)
      @runner = runner
      @compiler = compiler
      @linker = linker
      @fiasco = fiasco
      @codec = ABI::Codec.new(ABI::Generator.plan(root: @root).schema)
    end

    # Packs the image from Fiasco's last build into a directory that must be clean, so a
    # stale file cannot stand in for this build's.
    def build(directory:)
      directory = OutputDirectory.prepare(root: @root, path: directory)
      raise Error, 'a production image builds into a clean directory' unless Dir.empty?(directory)

      root_task = NativeRoot.new(root: @root, runner: @runner, compiler: @compiler, linker: @linker, fiasco: @fiasco)
                            .build_system_receipted(directory: File.join(directory, 'root'))
      kernel = assembled_receipt(@fiasco.kernel_path, name: 'kernel', directory: directory)
      sigma0 = assembled_receipt(@fiasco.sigma0_path, name: 'sigma0', directory: directory)
      archive = File.join(directory, 'image.erxpack')
      report = pack(entries: entries(root_task, kernel, sigma0), root_task: root_task, receipts: [kernel, sigma0],
                    output: archive)
      single = File.join(directory, 'image.boot')
      BootFile.write(codec: @codec, first_stage: @fiasco.image_path, archive: archive, output: single, output_root: @root)
      header = @codec.decode_layout('erx_pack_header', File.binread(archive, @codec.layout_size('erx_pack_header')))
      Built.new(single: single, archive: archive, first_stage: @fiasco.image_path,
                index_hash: header.fetch('index_hash').unpack1('H*'), build_id: header.fetch('build_id').unpack1('H*'),
                report: report)
    end

    # The same inputs give byte-identical images: two builds in clean directories of different
    # names, so a path that reached an output shows. Fiasco's own assembly has its own
    # test (test/integration/fiasco_reproducible_test.rb); both builds here pack its one result.
    def check_reproducible(directory:)
      directory = OutputDirectory.prepare(root: @root, path: directory)
      raise Error, 'a reproducibility check needs a clean directory' unless Dir.empty?(directory)

      first, second = %w[first second].map { |name| build(directory: File.join(directory, name)) }
      differing = %i[archive single].reject { |part| File.binread(first.public_send(part)) == File.binread(second.public_send(part)) }
      report = { 'kind' => 'production_image_reproducibility', 'byte_identical' => differing.empty?,
                 'differing' => differing.map(&:to_s), 'first' => digests(first), 'second' => digests(second),
                 'manifest' => first.report.fetch('manifest') }
      path = File.join(directory, 'result.json')
      File.write(path, JSON.pretty_generate(report) + "\n")
      unless differing.empty?
        raise Error, "the production image differs across clean builds: #{differing.join(', ')}; #{path}"
      end

      report.merge('report' => path).freeze
    end

    # The problems of a platform record against a device tree as dtc prints it: a path the
    # tree lacks, or a node whose compatible list does not name what the record says.
    def self.device_path_problems(platform, dts)
      nodes = dts.scan(/^\t([^\s{}]+) \{\n(.*?)^\t\};/m).to_h do |name, body|
        ["/#{name}", body[/^\t\tcompatible = (.*?);/, 1].to_s.scan(/"([^"]+)"/).flatten]
      end
      devices = platform.fetch('units').flat_map { |unit| unit.fetch('devices') }
      devices.filter_map do |device|
        path = device.fetch('path')
        if !nodes.key?(path)
          "#{path}: not in the device tree"
        elsif !nodes.fetch(path).include?(device.fetch('compatible'))
          "#{path}: compatible #{nodes.fetch(path).inspect} does not name #{device.fetch('compatible')}"
        end
      end
    end

    # Boots the production image under each accelerator and CPU count, after checking
    # the platform record's device paths against QEMU's own device tree. Any disagreement raises.
    class Run
      def initialize(root:, runner: Runner.new(owner_root: root, log_dir: File.join(root, 'build/logs')),
                     compiler: ENV.fetch('ERX_CLANG', ''), linker: ENV.fetch('ERX_LLD', ''), qemu: 'qemu-system-aarch64')
        @root = File.expand_path(root)
        @runner = runner
        @compiler = compiler
        @linker = linker
        @qemu = qemu
      end

      def call(accels:, cpus: [1, 4], jobs: 4, build: true)
        fiasco = Fiasco.new(root: @root, runner: @runner, compiler: @compiler)
        fiasco.build(jobs: jobs) if build
        check_device_paths
        built = image(fiasco)
        accels.product(cpus).to_h do |accel, count|
          full = boot(accel, count, built, memory_mib: MEMORY_MIB, points: Run.checkpoints(built, root: @root))
          # This boot's transcript is its whole result: it raises if the refusal is missing.
          boot(accel, count, built, memory_mib: TOO_LITTLE_MEMORY_MIB, points: Run.refusal_checkpoints)
          ["#{accel}-#{count}cpu", { serial: full.fetch('serial_log'), seconds: full.fetch('elapsed_seconds') }.freeze]
        end
      end

      # The transcript of a boot to where ERTS starts, each line in order. The manifest
      # line carries the numbers the source says, so a root that misread it fails.
      def self.checkpoints(built, root:)
        source = File.read(File.join(root, MANIFEST))
        memory, baseline = %w[root_memory system_baseline].map { |key| source[/^\s*#{key} (\d+)$/, 1] }
        units = source.scan(/^unit /).size
        identity = /\Aerx: root task: build #{built.build_id} index #{built.index_hash} entries [0-9]+\r?\n\z/n
        manifest = /\Aerx: root task: manifest root_memory #{memory} baseline #{baseline} units #{units} pool pages [0-9]+\r?\n\z/n
        [*Qemu.boot_transcript(memory_mib: MEMORY_MIB),
         point('root-identity', /\Aerx: root task: build/n, identity),
         point('root-manifest', /\Aerx: root task: manifest/n, manifest),
         { name: 'root-erts-point', pattern: /\Aerx: root task: ERTS starts here; this image holds no ERTS/n, seconds: 30 }.freeze].freeze
      end

      # A machine with less RAM than root_memory: the same image boots to the root, which
      # says so and ends the machine before anything would start.
      def self.refusal_checkpoints
        [*Qemu.boot_transcript(memory_mib: TOO_LITTLE_MEMORY_MIB),
         { name: 'root-refusal', pattern: /\Aerx: root task refused the boot: manifest: root_memory is more than/n, seconds: 30 }.freeze].freeze
      end

      def self.point(name, pattern, whole)
        { name: name, pattern: pattern, seconds: 30,
          verify: ->(text) { raise Error, "the root task reports #{text.inspect}" unless whole.match?(text) } }.freeze
      end
      private_class_method :point

      private

      def boot(accel, count, built, memory_mib:, points:)
        Qemu.new(root: @root, runner: @runner, program: @qemu)
            .run(accel: accel, cpus: count, image: built.single, memory_mib: memory_mib, checkpoints: points, machine_end: true)
      end

      def image(fiasco)
        directory = File.join(@root, 'build/production-image/boot')
        FileUtils.remove_entry(directory) if File.exist?(directory)
        ProductionImage.new(root: @root, runner: @runner, compiler: @compiler, linker: @linker, fiasco: fiasco).build(directory: directory)
      end

      # QEMU writes its own device tree and exits; two serial ports, since the second
      # UART exists only when a second port is given.
      def check_device_paths
        directory = File.join(@root, 'build/production-image/device-tree')
        FileUtils.mkdir_p(directory)
        tree = File.join(directory, 'virt.dtb')
        @runner.run([@qemu, '-machine', "virt,dumpdtb=#{tree}", '-cpu', 'cortex-a72', '-m', MEMORY_MIB.to_s, '-display', 'none',
                     '-serial', 'null', '-serial', 'null', '-no-reboot'], name: 'qemu-dumpdtb', deadline: 30)
        listing = @runner.run(['dtc', '-q', '-I', 'dtb', '-O', 'dts', tree], name: 'dtc-virt', deadline: 30)
        platform = JsonInput.parse(File.binread(File.join(@root, PLATFORM)), max_bytes: 65_536, label: 'platform record')
        problems = ProductionImage.device_path_problems(platform, File.read(listing.fetch('log')))
        raise Error, "#{PLATFORM} disagrees with QEMU's device tree: #{problems.join('; ')}" unless problems.empty?
      end
    end

    private

    def entries(root_task, kernel, sigma0)
      file = @codec.member('entry_kind', 'file')
      program = root_task.fetch(:program)
      receipt = root_task.fetch(:receipt)
      plain = { 'kind' => file, 'flags' => 0 }.freeze
      [plain.merge('path' => @codec.fixed_bytes('boot_kernel_path'), 'id' => 'kernel', 'artifact' => @fiasco.kernel_path, 'receipt' => kernel),
       plain.merge('path' => @codec.fixed_bytes('boot_sigma0_path'), 'id' => 'sigma0', 'artifact' => @fiasco.sigma0_path, 'receipt' => sigma0),
       # bootstrap loads this one, as an ELF file; the header's root entry below
       # is the same program as an image, which the manifest check sizes.
       plain.merge('path' => @codec.fixed_bytes('boot_stand_in_root_path'), 'id' => 'root-file', 'artifact' => program, 'receipt' => receipt),
       { 'path' => ROOT_ENTRY_PATH, 'kind' => @codec.member('entry_kind', 'image'), 'flags' => @codec.member('entry_flags', 'system'),
         'id' => 'root', 'artifact' => program, 'receipt' => receipt }]
    end

    def pack(entries:, root_task:, receipts:, output:)
      tools = PackTools.build(root: @root, owner_root: @root, directory: File.join(@root, 'build/production-image-tools'),
                              runner: @runner, compiler: @compiler, sanitizers: [])
      # The root's reader of the archive includes BLAKE3's header, imported into the tree.
      provenance = PackProvenance.new(root: @root, catalog: catalog(root_task, receipts), external: external, runner: @runner,
                                      imports: { 'kernel/crypto/blake3' => 'permanent' }, compiler: @compiler)
      paths = (entries.map { |entry| entry.fetch('path') } + [@codec.fixed_bytes('system_manifest_path'), NOTICES_PATH]).map(&:b).sort
      platform = JsonInput.parse(File.binread(File.join(@root, PLATFORM)), max_bytes: 65_536, label: 'platform record')
      Pack.new(root: @root, output_root: @root, codec: @codec, planner: ElfPlanner.new(helper: tools.fetch('planner'), runner: @runner, codec: @codec),
               checker: tools.fetch('checker'), hasher: tools.fetch('hasher'), runner: @runner, provenance: provenance)
          .build(entries: entries, root_path: ROOT_ENTRY_PATH, build_kind: 'development', platform: platform,
                 artifacts: { 'root' => { 'kind' => 'executable', 'entry' => paths.index(ROOT_ENTRY_PATH) } },
                 manifest_source: File.binread(File.join(@root, MANIFEST)), output: output)
    end

    def catalog(root_task, receipts)
      fiasco = [@fiasco.kernel_path, @fiasco.sigma0_path, @fiasco.image_path, File.join(@root, 'build/fiasco/receipt.json'),
                File.join(@root, 'build/fiasco/provenance.json'), File.join(@root, 'tools/lib/erx/fiasco.rb')]
      BuildInputs.pack(root: @root, paths: [*root_task.fetch(:inputs), *receipts, *fiasco])
    end

    # A receipt that says the kernel or sigma0 comes from Fiasco's audited build.
    def assembled_receipt(artifact, name:, directory:)
      receipt = { 'version' => 1, 'kind' => 'assembled', 'artifact' => reference(artifact),
                  'components' => [reference(File.join(@root, 'build/fiasco/receipt.json'))],
                  'producer' => reference(File.join(@root, 'tools/lib/erx/fiasco.rb')) }
      path = File.join(directory, "#{name}.receipt.json")
      File.write(path, JSON.pretty_generate(receipt) + "\n")
      path
    end

    # The clang that built the root, and Fiasco's archives its link takes members of.
    def external
      resource = @runner.run([@compiler, '-print-resource-dir'], name: 'clang-resource-directory', deadline: 30)
      installation = File.expand_path('../../..', File.read(resource.fetch('log')).strip)
      ToolchainProvenance.registry(profile: File.join(@root, 'config/provenance/llvm-23.1.3.json'), installation: installation) +
        archives.map { |archive| external_archive(archive) }
    end

    def archives
      spdx = 'fiasco/l4re-core/LICENSE.spdx'
      [Archive.new(path: @fiasco.user_library('libl4sys.p.a'), label: 'fiasco/l4re-core libl4sys',
                   license: 'MIT', status: 'stopgap', notice: spdx),
       Archive.new(path: @fiasco.user_library('libsigma0.a'), label: 'fiasco/l4re-core libsigma0',
                   license: 'MIT', status: 'stopgap', notice: spdx),
       Archive.new(path: @fiasco.boot_core_archive, label: 'kernel/core boot cores',
                   license: 'BSD-2-Clause', status: 'permanent', notice: LICENSE)]
    end

    def external_archive(archive)
      reference(archive.path).merge('path' => File.realpath(archive.path), 'label' => archive.label, 'license' => archive.license,
                                    'evidence' => 'archive built by tools/lib/erx/fiasco.rb, attributed as a whole',
                                    'status' => archive.status, 'notices' => [reference(File.join(@root, archive.notice))])
    end

    def reference(path)
      { 'path' => path.delete_prefix("#{@root}/"), 'sha256' => Digest::SHA256.file(path).hexdigest }
    end

    def digests(built)
      { 'archive_sha256' => Digest::SHA256.file(built.archive).hexdigest,
        'single_sha256' => Digest::SHA256.file(built.single).hexdigest }
    end
  end
end
