# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'digest'
require 'fileutils'
require 'json'
require 'tmpdir'
require_relative 'runner'
require_relative 'bounded_file'
require_relative 'build_memo'
require_relative 'host_os'
require_relative 'boot_file'
require_relative 'json_input'
require_relative 'sources'
require_relative 'fiasco_inputs'
require_relative 'fiasco_parts'
require_relative 'fiasco_config'
require_relative 'build_kind'
require_relative 'core_archive'
require_relative 'stack_proof_run'
require_relative 'glue_imports'
require_relative 'fiasco_toolchain'
require_relative 'host_path'
require_relative 'file_lock'
require_relative 'output_directory'
require_relative 'origin'
require_relative 'import_notices'
require_relative 'license_expression'

module Erx
  class Fiasco
    IMPLEMENTATION_SHA256 = Digest::SHA256.file(__FILE__).hexdigest.freeze
    # L4Re's user libraries, which the root links (in this order) and every image and
    # the SDK ship: each library's license, as fiasco/l4re-core/LICENSE.spdx declares
    # it for their packages, and the directories of the files it is compiled from: its
    # own sources and the headers they include. user_library_notices derives the
    # notices both ship them under from these.
    UserLibrary = Data.define(:license, :sources)
    USER_LIBRARIES = {
      'libsigma0.a' => UserLibrary.new(license: 'MIT', sources: %w[libsigma0/include libsigma0/lib l4sys/include cxx/lib/tl/include]
                                         .map { "fiasco/l4re-core/#{it}" }.freeze),
      'libl4sys.p.a' => UserLibrary.new(license: 'MIT', sources: %w[l4sys/include l4sys/lib cxx/lib/tl/include]
                                          .map { "fiasco/l4re-core/#{it}" }.freeze)
    }.freeze
    KERNEL_COMMIT = '07ea18e1f293bda6b9f75e59707ee1c70cf4321f'
    CORE_COMMIT = 'e2e2d5af9de7aa0e1df2a25ebadee54488fa4a49'
    # SHA-256 of git archives with no prefix, at the full commits above.
    KERNEL_SHA256 = 'e2f96d3ba1c15d4981d42b2f37258a082220e8e10cf72361c208519d4cd6f8ee'
    CORE_SHA256 = '6c55c02804ecd86de2b103163341b6f911d3945108b611fa9d7f38a99a2e1f3f'
    ARCHIVES = {
      'mk' => {
        'commit' => '22cc26e5c971f65a1425d8cae87d793c2573528a',
        'sha256' => '98c8b2b81391cfee4797586e150fc74bd5ba48a2decdcb18e7daa5ccc3db3097'
      }.freeze,
      'bootstrap' => {
        'commit' => 'a4f4ad182c78a97a1c50098511092dd32f05c63d',
        'sha256' => 'e6ec5fa08e6ae44ef88263428c2f5936ce0bd804b99626858a330b141e7043dc'
      }.freeze,
      'libfdt' => {
        'commit' => '5756062b7067dd831b0ef7a7f841a3f63a8b8a22',
        'sha256' => '4c5d66c202a33c3af29dc7b4315d8ec56357936db9a8a8193773c724d063392f'
      }.freeze,
      'drivers-frst' => {
        'commit' => '6459d70997da1a2ad97775c8772b4a41284b0a9e',
        'sha256' => '3eb24fe67cf4eb7968ba5379016befd3fb72977066a3708468290e9a9ca9f4ff'
      }.freeze
    }.freeze
    KERNEL_EXCLUSIONS = %w[
      src/lib/regex src/lib/simple_malloc src/lib/gcov src/lib/perfctr
      src/kern/arm/bsp/qcom src/test src/jdb/jdb_cov_module.cpp src/drivers/stream_crc32.cpp
    ].freeze
    CORE_PACKAGES = %w[
      compiler-rt compiler-rt-crt compiler-rt-pure crtn cxx cxx_libc_io
      l4re l4re_c l4sys l4util ldscripts libc libc-headers libc-minimal
      libc_backends libsigma0
      minimal_l4re sigma0
    ].freeze
    UART_FILES = %w[
      Makefile Control Kconfig.L4 LICENSE.spdx README
      include/Makefile include/io_regblock.h include/poll_timeout_counter.h
      include/ARCH-arm64/asm_access.h
      uart/Makefile uart/include/Makefile
      uart/include/device.h uart/include/uart_base.h uart/include/uart_pl011.h
      uart/src/Makefile uart/src/uart_pl011.cc
      uart/include/uart_16550.h uart/include/uart_16550_dw.h uart/include/uart_bcm2835.h
      uart/src/uart_16550.cc uart/src/uart_16550_dw.cc uart/src/uart_bcm2835.cc
    ].freeze
    # The boards whose bootstrap is a build of its own, by platform record name, and the
    # configuration of each (docs/design-fiasco.md, "The Raspberry Pi 4"). The Pi's is
    # Fiasco's generic platform, linked static at 2 MiB, with RAM at 0 and the mini UART's
    # 16550 driver; QEMU virt's is the main build's (user.defconfig).
    BOARD_BOOTSTRAPS = { 'raspi4b' => 'user-raspi4b.defconfig' }.freeze
    # Fiasco's own options, which bootstrap passes to the kernel. None: without
    # -serial_esc or -serial_input the kernel leaves the UART's interrupt free
    # for the console driver (docs/design-fiasco.md, "The console").
    KERNEL_OPTIONS = ''
    # Where the inherited build leaves bootstrap's objects and images.
    BOOTSTRAP_OBJECTS = 'pkg/bootstrap/server/src/OBJ-arm64_armv8a-nofpu-plain'
    # Upper bound of a record this tool writes into the build tree.
    BUILD_RECORD_BYTES = 65_536
    # Beside the LLVM toolchain (FiascoToolchain), which the build runs by absolute
    # path, one program of each
    # package the build runs from outside the operating system: GNU make, gawk (the
    # inherited Makeconf's AWKP), dtc and perl (Fiasco's preprocessor). Every other
    # program the inherited rules run (cp, find, sed, ln) is the first of its name on the
    # build's PATH, the operating system's own unless a package directory before it holds
    # one, and the rules use the forms macOS, FreeBSD and Linux share. The directory each of these really
    # lives in goes on the build's PATH (program_directories), so the build finds every
    # other program of those packages beside it, and memo_key names every program in
    # those directories. On FreeBSD that is /usr/local/bin, a directory every package
    # shares. PROGRAMS also names the host compilers (HostOs::HOST_CC, HOST_CXX), so a
    # host without them fails before the build.
    PROGRAMS = [*%w[gmake gawk dtc perl], HostOs::HOST_CC, HostOs::HOST_CXX].freeze
    # The build's memo step (BuildMemo#in_place).
    MEMO_STEP = 'fiasco'
    # The lock of build/fiasco (FileLock), which every build into it holds exclusively
    # (with_tree_lock): processes that build in one tree at once, as make check's test
    # files do, take turns instead of running make over each other's directories, and a
    # build that waited reuses the one that finished meanwhile (BuildMemo). The notices
    # user_library_notices publishes by rename are not a build and take no lock.
    LOCK = 'build/fiasco/.lock'

    # compiler is the LLVM clang that builds the C17 cores' archive; the
    # resource headers it compiles with must be those the reviewed LLVM
    # profile admits (ToolchainProvenance.llvm). With linker, LLVM's ld.lld, it is also the
    # toolchain that builds Fiasco and L4Re (FiascoToolchain). kernel, when given, is the
    # kernel an image packs in kernel_path's place: a test kernel (build_test_kernel).
    def initialize(root:, runner: Runner.new(owner_root: root, log_dir: File.join(root, 'build/logs')),
                   compiler: ENV.fetch('ERX_CLANG', ''), linker: ENV.fetch('ERX_LLD', ''), kernel: nil)
      @kernel = kernel
      @root = File.expand_path(root)
      @runner = runner
      @compiler = compiler
      @linker = linker
      @source = File.join(@root, 'fiasco')
      @build = File.join(@root, 'build/fiasco')
    end

    # One-time import accepts explicit local caches. Normal builds only read
    # the committed trees, and never contact a remote or inspect those caches.
    def import_sources(kernel_repo:, core_repo:, archive_cache:)
      raise Error, 'Fiasco source destination already exists' if File.exist?(@source)

      OutputDirectory.prepare(root: @root, path: File.dirname(@source))
      Dir.mktmpdir('.fiasco-import-', File.dirname(@source)) do |temporary|
        stage = File.join(temporary, 'fiasco')
        FileUtils.mkdir_p(stage)
        identities = []
        identities << import_git(kernel_repo, commit: KERNEL_COMMIT,
                                 sha256: KERNEL_SHA256, name: 'kernel',
                                 temporary: temporary, stage: stage)
        identities << import_git(core_repo, commit: CORE_COMMIT,
                                 sha256: CORE_SHA256, name: 'l4re-core',
                                 temporary: temporary, stage: stage)
        ARCHIVES.each do |name, pin|
          identities << import_archive(name, pin: pin, cache: archive_cache,
                                       temporary: temporary, stage: stage)
        end
        trim_sources(stage)
        File.write(File.join(stage, 'IMPORTS.json'), JSON.pretty_generate(identities) + "\n")
        File.rename(stage, @source)
      end
    end

    def build(jobs: 4)
      raise Error, 'jobs must be between 1 and 64' unless jobs.is_a?(Integer) && jobs.between?(1, 64)
      raise Error, 'set ERX_CLANG to an installed LLVM clang; see README.md' if @compiler.to_s.empty?
      raise Error, 'imported Fiasco source root must not be a symlink' if File.symlink?(@source)
      FiascoParts::NAMES.each do |name|
        path = File.join(@source, name)
        raise Error, "missing or external imported Fiasco part: #{name}" unless File.directory?(path) && !File.symlink?(path)
      end
      memo = BuildMemo.new(root: @root)
      before_waiting = memo.stamp(MEMO_STEP)
      with_tree_lock do
        prepare_source_cache
        # A build whose every input is unchanged since the last finished one, with that
        # build's outputs in place, does nothing (memo_key); make would find nothing to do
        # but takes a minute to find it, and the audit after it would find what it found.
        memo.in_place(MEMO_STEP, key: memo_key, outputs: memo_outputs, written_since: before_waiting) do
          cores = build_cores
          build_kernel(jobs: jobs, cores: cores, kind: BuildKind::DEVELOPMENT,
                       directory: self.class.kernel_directory(root: @root, kind: BuildKind::DEVELOPMENT))
          boot_cores = build_boot_cores
          users = build_users(jobs: jobs, boot_cores: boot_cores)
          build_image(users: users)
          record_provenance
        end
      end
      image_path
    end

    # The kernel again with a test's defines, in its own directory: for a suite
    # that must hold a window open or seed a fault, which no image but that suite's
    # ever boots. kind is the configuration it is built from (BuildKind). No test
    # kernel is audited, since nothing ships one.
    def build_test_kernel(name:, defines:, kind: BuildKind::DEVELOPMENT, jobs: 4)
      with_tree_lock do
        build_kernel_beside(directory: File.join(@build, "test-kernel-#{name}"), kind: kind,
                            defines: defines, jobs: jobs)
      end
    end

    # The release kernel (docs/design-fiasco.md, "The kernel"): the same sources and cores,
    # configured from the release defconfig (FiascoConfig.release_defconfig) and checked
    # with the release rules, in Fiasco.kernel_directory. No image packs it:
    # every image is a development build (ProductionImage::BUILD_KIND). The kernel's
    # link audit (FiascoProvenance#certify) must find every source it links under terms a
    # release may carry, or the build fails naming each source that is not. The kernel stays
    # only beside the audit's pass record: an earlier record goes before the build, and a
    # build that fails anywhere after it removes the kernel and any record.
    def build_release_kernel(jobs: 4)
      require_relative 'fiasco_provenance'
      directory = self.class.kernel_directory(root: @root, kind: BuildKind::RELEASE)
      kernel = File.join(directory, 'fiasco')
      record = File.join(directory, FiascoProvenance::PASS_RECORD)
      with_tree_lock do
        FileUtils.rm_f(record)
        passed = false
        build_kernel_beside(directory: directory, kind: BuildKind::RELEASE, defines: [], jobs: jobs)
        provenance_auditor(kind: BuildKind::RELEASE).certify
        passed = true
        kernel
      ensure
        FileUtils.rm_f([kernel, record]) unless passed
      end
    end

    # Where the tree at root builds the kernel of build kind kind: build's own kernel for
    # development, build_release_kernel's for release. Its globalconfig.out is the resolved
    # configuration, which tools/check_fiasco_config.rb checks.
    def self.kernel_directory(root:, kind:)
      File.join(File.expand_path(root), 'build/fiasco', BuildKind.development?(kind) ? 'kernel' : 'kernel-release')
    end

    # A board's own bootstrap (BOARD_BOOTSTRAPS): built from the same imported sources
    # and boot cores as the main one, in users-NAME, and copied out as
    # images/bootstrap-NAME.raw. The kernel and sigma0 stay the main build's, which
    # must have run.
    def build_board_bootstrap(name, jobs: 4)
      config = BOARD_BOOTSTRAPS.fetch(name) { raise Error, "platform #{name} has no bootstrap build of its own" }
      raise Error, 'jobs must be between 1 and 64' unless jobs.is_a?(Integer) && jobs.between?(1, 64)

      with_tree_lock do
        prepare_source_cache
        users = build_users(jobs: jobs, boot_cores: build_boot_cores,
                            directory: File.join(@build, "users-#{name}"), config: config)
        build_image(users: users, output: board_image_path(name))
      end
    end

    def board_image_path(name) = File.join(@build, "images/bootstrap-#{name}.raw")

    # What an image for platform packs: the main build and, for a board with a
    # bootstrap of its own, that bootstrap (first_stage_path).
    def build_for(platform, jobs: 4)
      build(jobs: jobs)
      build_board_bootstrap(platform.name, jobs: jobs) if BOARD_BOOTSTRAPS.key?(platform.name)
    end

    # The first stage an image for platform boots from: its board's own bootstrap build
    # (BOARD_BOOTSTRAPS), or the main build's for any other board.
    def first_stage_path(platform) = BOARD_BOOTSTRAPS.key?(platform.name) ? board_image_path(platform.name) : image_path

    # Where that first stage loads and runs: its link address, the entry of the ELF file
    # its flat image was made from. Bootstrap never relocates itself
    # (bootstrap/server/src/Make.rules), and QEMU's loader and the Pi's firmware put it
    # there (docs/design-platforms.md, "Boot"), so the single file
    # starts there.
    def first_stage_address(platform)
      users = BOARD_BOOTSTRAPS.key?(platform.name) ? "users-#{platform.name}" : 'users'
      self.class.elf_entry(File.binread(File.join(@build, users, BOOTSTRAP_OBJECTS, 'bootstrap.elf'), 64) || '')
    rescue SystemCallError => error
      raise Error, "cannot read the first stage's link address: #{error.message}"
    end

    # The entry address of a 64-bit little-endian executable ELF file (type ET_EXEC), from
    # its header's first 64 bytes. Whether the address lies in the machine's RAM is the
    # caller's check (ProductionImage::Machine#check_single_file).
    def self.elf_entry(header)
      raise Error, "the first stage's ELF file has no 64-bit little-endian header" unless
        header.bytesize == 64 && header.start_with?("\x7fELF\x02\x01".b)
      raise Error, "the first stage's ELF file is not an executable (ET_EXEC)" unless
        header.unpack1('S<', offset: 16) == ELF_TYPE_EXEC

      header.unpack1('Q<', offset: 24)
    end

    ELF_TYPE_EXEC = 2

    # The first stage as built: bootstrap's flat image, with neither locator
    # field written (docs/design-kernel.md, "The bootable file"). What boots is
    # this with an archive; BootImage writes both forms.
    def image_path
      File.join(@build, 'images/bootstrap.raw')
    end

    # The kernel and sigma0 the recipe packs, once built: the kernel given to new, or the
    # development kernel.
    def kernel_path = @kernel || File.join(self.class.kernel_directory(root: @root, kind: BuildKind::DEVELOPMENT), 'fiasco')
    def sigma0_path = File.join(@build, 'users/bin/arm64_armv8a/std/l4f/sigma0')

    # The kernel's name as uname -K shows it (BuildFacts): fiasco- and the first 12
    # hex digits of the upstream revision fiasco/kernel/ORIGIN.md records.
    def kernel_name
      revision = Origin.new(root: File.join(@source, 'kernel')).inventory.fetch('revision')
      raise Error, "fiasco/kernel/ORIGIN.md's revision is not a commit: #{revision.inspect}" unless
        revision.is_a?(String) && revision.match?(/\A[0-9a-f]{40}\z/)

      "fiasco-#{revision[0, 12]}"
    end

    # What a native root task compiles and links against, once built.
    def user_include_directories
      %w[include/arm64/l4f include/arm64 include/l4f include].map { |path| File.join(@build, 'users', path) }
    end

    def user_library(name) = File.join(@build, 'users/lib/arm64_armv8a/std/l4f', name)

    # The notices user library name ships under, paths under the tree: its license's
    # documents (user_license_notices) and a document of the copyright notices of its
    # packages' files, written under build/fiasco/notices whole or not at all: staged
    # beside it and renamed into place, so a reader never meets a half-written one.
    # OutputDirectory makes the directory, and names whatever else holds its place.
    def user_library_notices(name)
      profile = ImportNotices.parse(File.binread(File.join(@root, ImportNotices::PROFILE)))
      directory = File.join(@build, 'notices')
      OutputDirectory.prepare(root: @root, path: directory)
      copyrights = File.join(directory, "#{name}.copyright")
      Dir.mktmpdir('.notices-', directory) do |staging|
        staged = File.join(staging, 'copyright')
        File.binwrite(staged, Fiasco.user_copyrights(name, root: @root))
        File.rename(staged, copyrights)
      end
      [*Fiasco.user_license_notices(name, profile: profile, root: @root), copyrights.delete_prefix("#{@root}/")]
    end

    # What import-notices.json gives user library name's sources for each grant of its
    # license: l4re-core's LICENSE.spdx, which declares the license, and the license's
    # permission text, each held to the profile's SHA-256. A grant the profile gives no
    # text would ship the library without its license, so it fails the build.
    def self.user_license_notices(name, profile:, root:)
      library = USER_LIBRARIES.fetch(name)
      grants = LicenseExpression.select(library.license, allow_restricted: false).fetch('grants')
      references = library.sources.flat_map do |source|
        missing = grants.select { |grant| ImportNotices.grant_documents(profile, source: source, grant: grant).empty? }
        raise Error, "#{name} would ship without the text of #{missing.join(', ')}: #{ImportNotices::PROFILE} gives #{source} none" unless missing.empty?

        ImportNotices.select(profile, source: source, grants: grants)
      end
      references.uniq.map do |reference|
        path = reference.fetch('path')
        file = File.join(root, path)
        raise Error, "#{path} differs from #{ImportNotices::PROFILE}" unless File.file?(file) && Digest::SHA256.file(file).hexdigest == reference.fetch('sha256')

        path
      end
    end

    # The copyright notices of user library name's sources, each file's own text byte
    # for byte (copyright_comment), given once under the first file that carries it.
    def self.user_copyrights(name, root:)
      sources = USER_LIBRARIES.fetch(name).sources
      carriers = sources.flat_map { |source| source_copyrights(source, root: root) }.group_by(&:last)
      notices = carriers.map { |comment, files| "\n#{files.first.first}:\n#{comment}" }
      "Copyright notices of the files #{name} is compiled from (#{sources.join(', ')})\n".b + notices.join.b
    end

    # [path, copyright comment] for each file under source, a directory of the tree,
    # that states a copyright. A directory that is missing or states none fails, since
    # a user library's notice would then ship without its holders.
    def self.source_copyrights(source, root:)
      directory = File.join(root, source)
      files = Dir.glob('**/*', base: directory).sort.select { |file| File.file?(File.join(directory, file)) }
      found = files.filter_map do |file|
        comment = copyright_comment(File.binread(File.join(directory, file)))
        [File.join(source, file), comment] if comment
      end
      raise Error, "#{source} states no copyright, so a user library's notice would lack its holders" if found.empty?

      found
    end

    # The comment blocks of a C, C++ or assembly file's opening (its comments,
    # preprocessor and blank lines before the first code) up to and including the last
    # that states a copyright, so the blocks naming the authors a "(c) Author(s)"
    # statement refers to come with it; nil when none states one.
    def self.copyright_comment(bytes)
      blocks = []
      lines = bytes.b.lines
      until lines.empty?
        first = lines.shift
        opening = first.lstrip
        next if opening.strip.empty? || opening.start_with?('#')
        break unless opening.start_with?('/*', '//')

        block = [first]
        block << lines.shift while opening.start_with?('/*') && !block.last.include?('*/') && !lines.empty?
        blocks << block.join
      end
      last = blocks.rindex { |block| block.match?(/\(c\)|copyright/i) }
      last && blocks[0..last].join
    end

    def boot_core_archive = File.join(@build, 'boot-cores', CoreArchive::BOOT_ARCHIVE)

    private

    # Runs the block holding build/fiasco's lock (LOCK) exclusively, waiting while another
    # process builds there, and returns its value.
    def with_tree_lock(&)
      OutputDirectory.prepare(root: @root, path: @build)
      FileLock.hold(File.join(@root, LOCK), what: "the Fiasco build tree of #{@root}", busy: :wait, &)
    end

    # What the build reads: every captured input by content (FiascoInputs' record), the
    # Ruby that drives it, every program of the LLVM toolchain, and the environment it
    # runs in. Beside that toolchain the build finds programs only on that environment's
    # PATH, which holds the operating system's directories, named by its release, and
    # directories every program of which the key names by identity.
    def memo_key
      environment = build_environment.compact
      programs = environment.fetch('PATH').split(File::PATH_SEPARATOR).reject { |directory| BuildMemo::SYSTEM_DIRECTORIES.include?(directory) }
                            .to_h { |directory| [directory, BuildMemo.directory_identities(directory)] }
      BuildMemo.key('inputs' => @captured.fetch('sha256'), 'tools' => BuildMemo.tools_digest(root: @root),
                    'toolchain' => toolchain.programs.map { |program| BuildMemo.program_identity(program) },
                    'programs' => programs,
                    'system' => BuildMemo.system_release, 'environment' => environment)
    end

    # What the build leaves for the image and the native builds, and the receipt that
    # vouches for it: a hit needs each with the bytes the finished build left, the header
    # trees the native compiles include by content (BuildMemo#in_place).
    def memo_outputs
      [image_path, kernel_path, sigma0_path, boot_core_archive, *USER_LIBRARIES.keys.map { |name| user_library(name) },
       *user_include_directories, File.join(@build, 'receipt.json'), File.join(@build, 'provenance.json')]
    end

    def record_provenance = provenance_auditor(kind: BuildKind::DEVELOPMENT).certify

    # The link audit of the kernel of build kind kind, over this build's toolchain.
    def provenance_auditor(kind:)
      require_relative 'fiasco_provenance'
      FiascoProvenance.new(root: @root, runner: @runner, kind: kind,
                           external: FiascoProvenance.llvm_registry(root: @root, compiler: @compiler, runner: @runner),
                           toolchain: toolchain)
    end

    # Inherited dependency stamps do not cover every generator's code or the
    # toolchain. A source or toolchain change therefore discards that
    # component's derived outputs; ordinary incremental work is reused only
    # for the same source bytes and toolchain installation.
    def prepare_source_cache
      @inputs = FiascoInputs.new(root: @root)
      captured = @captured = @inputs.prepare
      expected = {
        'kernel' => Digest::SHA256.hexdigest(IMPLEMENTATION_SHA256 + CoreArchive::IMPLEMENTATION_SHA256 + toolchain_identity(toolchain.kernel_settings) +
                                             @inputs.component_id(captured, component: 'kernel')),
        'users' => Digest::SHA256.hexdigest(IMPLEMENTATION_SHA256 + toolchain_identity(toolchain.user_settings) + @inputs.component_id(captured, component: 'users'))
      }
      marker = File.join(@build, '.erx-inputs.json')
      previous = {}
      if File.file?(marker)
        previous = read_build_record(marker, label: 'Fiasco source record', remedy: 'recreate the build directory')
      end
      valid = previous.is_a?(Hash) &&
              (previous.empty? || (previous.keys.sort == expected.keys.sort &&
                previous.values.all? { |value| value.is_a?(String) && /\A[0-9a-f]{64}\z/.match?(value) }))
      unless valid
        raise Error, 'invalid Fiasco source record; recreate the build directory'
      end
      changed = expected.keys.select { |name| previous[name] != expected.fetch(name) }
      # The users' inputs build every L4Re directory: the main one and each board's.
      discarded = changed.flat_map { |name| name == 'users' ? ['users', *BOARD_BOOTSTRAPS.keys.map { |board| "users-#{board}" }] : [name] }
      discarded.each do |name|
        path = File.join(@build, name)
        FileUtils.remove_entry(path) if File.exist?(path)
      end
      if changed.include?('users') && File.exist?(File.join(@build, 'source'))
        validate_user_source(File.join(@build, 'source'))
        FileUtils.remove_entry(File.join(@build, 'source'))
      end
      if !changed.empty? && File.exist?(File.join(@build, 'images'))
        FileUtils.remove_entry(File.join(@build, 'images'))
      end
      File.write(marker, JSON.pretty_generate(expected) + "\n")
    end

    def import_git(repository, commit:, sha256:, name:, temporary:, stage:)
      archive = File.join(temporary, "#{name}.tar")
      @runner.run(['git', '--no-replace-objects', '-C', File.expand_path(repository), 'archive', '--format=tar',
                   "--output=#{archive}", commit], name: "import-#{name}", deadline: 120)
      Sources.unpack(archive: archive, sha256: sha256,
                     destination: File.join(stage, name), owner_root: temporary, source_directory: '.', runner: @runner)
      { 'part' => name, 'repository' => "https://github.com/kernkonzept/#{name == 'kernel' ? 'fiasco' : name}",
        'revision' => commit, 'archive_sha256' => sha256 }
    end

    def import_archive(name, pin:, cache:, temporary:, stage:)
      filename = "#{name}-#{pin.fetch('commit')}.tar.gz"
      candidates = Dir.glob(File.join(File.expand_path(cache), '**', filename))
      raise Error, "expected one cached archive for #{name}" unless candidates.size == 1
      archive = candidates.first
      extracted = File.join(temporary, "unpacked-#{name}")
      Sources.unpack(archive: archive, sha256: pin.fetch('sha256'),
                     destination: extracted, owner_root: temporary,
                     source_directory: "#{name}-#{pin.fetch('commit')}", runner: @runner)
      File.rename(extracted, File.join(stage, name))
      { 'part' => name, 'repository' => "https://github.com/kernkonzept/#{name}",
        'revision' => pin.fetch('commit'), 'archive_sha256' => pin.fetch('sha256') }
    end

    def trim_sources(stage)
      kernel = File.join(stage, 'kernel')
      KERNEL_EXCLUSIONS.each { |path| FileUtils.remove_entry(File.join(kernel, path)) }
      core = File.join(stage, 'l4re-core')
      keep = CORE_PACKAGES + %w[LICENSE.spdx Makefile README.md SECURITY.md]
      Dir.children(core).reject { |path| keep.include?(path) }.each do |path|
        FileUtils.remove_entry(File.join(core, path))
      end
      %w[libc/uclibc-ng libc/musl/libpthread cxx/lib/start].each do |path|
        FileUtils.remove_entry(File.join(core, path))
      end
      retain_uart(File.join(stage, 'drivers-frst'))
    end

    def retain_uart(directory)
      selected = Dir.mktmpdir('.uart-', File.dirname(directory))
      UART_FILES.each do |relative|
        source = File.join(directory, relative)
        next if relative == 'README' && !File.exist?(source)
        raise Error, "missing pinned UART import file: #{relative}" unless File.file?(source)
        target = File.join(selected, relative)
        FileUtils.mkdir_p(File.dirname(target))
        FileUtils.copy_file(source, target)
      end
      FileUtils.remove_entry(directory)
      File.rename(selected, directory)
    ensure
      FileUtils.remove_entry(selected) if selected && File.exist?(selected)
    end

    # The C17 cores, built with LLVM from the captured inputs. The stack
    # proof reads the archive's own objects and must pass before the
    # archive is installed, so no kernel links cores whose depth is
    # unproven.
    def build_cores
      tree = @inputs.tree
      proof = lambda do |objects|
        StackProofRun.call(root: tree, compiler: @compiler, runner: @runner, project: @root,
                           output: File.join(@build, 'stack-proof'), archive: objects)
      end
      CoreArchive.build(root: tree, compiler: @compiler, runner: @runner, project: @root,
                        output: File.join(@build, 'cores'), check: proof)
    end

    # A kernel beside build's own, in directory, whose record discards it when a source
    # or the defines change, as a source change discards the real one.
    def build_kernel_beside(directory:, kind:, defines:, jobs:)
      prepare_source_cache
      cores = build_cores
      # Makeconf.local has no rule that rebuilds on a change, so the record holds the defines too.
      inputs = File.read(File.join(@build, '.erx-inputs.json')) + defines.join(' ')
      marker = File.join(directory, '.erx-kernel-inputs.json')
      current = File.file?(marker) && File.read(marker) == inputs
      FileUtils.remove_entry(directory) if File.exist?(directory) && !current
      build_kernel(jobs: jobs, cores: cores, kind: kind, directory: directory, defines: defines)
      File.write(marker, inputs)
      File.join(directory, 'fiasco')
    end

    def build_kernel(jobs:, cores:, kind:, directory:, defines: [])
      configure(source: @inputs.part('kernel'), directory: directory, input: kernel_defconfig(kind),
                output: 'globalconfig.out', name: "fiasco-#{File.basename(directory)}-config")
      # The resolved file, not the defconfig: a select can set an option the
      # defconfig leaves unset.
      FiascoConfig.check(File.join(directory, 'globalconfig.out'), kind: kind)
      # The kernel's Makeconf reads this file from its build directory.
      settings = self.class.make_settings(toolchain.kernel_settings)
      settings += "CPPFLAGS += #{defines.join(' ')}\n" unless defines.empty?
      File.write(File.join(directory, 'Makeconf.local'), settings)
      @runner.run(['gmake', '-C', directory, "-j#{jobs}", *toolchain_variables,
                   "ERX_CORE_ARCHIVE=#{cores.archive}", "ERX_CORE_INCLUDE=#{cores.seam}"],
                  name: "fiasco-#{File.basename(directory)}-build", deadline: 600, env: build_environment)
      GlueImports.check(source: @inputs.part('kernel'), allowlist: File.join(@source, GlueImports::ALLOWLIST),
                        objects: directory, nm: toolchain.program('nm'), runner: @runner, env: build_environment)
      directory
    end

    # The kernel defconfig of build kind kind: the checked-in development one, or the
    # release one derived from it, written into the build tree.
    def kernel_defconfig(kind)
      development = @inputs.configuration('kernel.defconfig')
      return development if BuildKind.development?(kind)

      directory = File.join(@build, 'release')
      OutputDirectory.prepare(root: @root, path: directory)
      path = File.join(directory, 'kernel-release.defconfig')
      File.binwrite(path, FiascoConfig.release_defconfig(BoundedFile.read(development, maximum: FiascoInputs::MAX_FILE)))
      path
    end

    def assemble_user_source
      directory = File.join(@build, 'source')
      validate_user_source(directory)

      # Inherited make canonicalizes source paths. A private physical copy
      # preserves that model and prevents its generators touching imports.
      Dir.mktmpdir('.source-', @build) do |temporary|
        staged = File.join(temporary, 'tree')
        FileUtils.cp_r(File.join(@inputs.part('mk'), '.'), staged, preserve: true)
        FileUtils.mkdir_p(File.join(staged, 'pkg'))
        %w[l4re-core bootstrap libfdt drivers-frst].each do |name|
          FileUtils.cp_r(@inputs.part(name), File.join(staged, 'pkg', name), preserve: true)
        end
        Dir.glob(File.join(staged, '**/*'), File::FNM_DOTMATCH).each do |path|
          File.chmod(File.stat(path).mode | 0o200, path) if File.file?(path) && !File.symlink?(path)
        end
        write_user_settings(File.join(staged, 'Makeconf.local'), previous: File.join(directory, 'Makeconf.local'))
        record = { 'owner' => 'erx-fiasco', 'source' => @source }
        File.write(File.join(staged, '.erx-source.json'), JSON.pretty_generate(record) + "\n")
        previous = File.join(temporary, 'previous')
        File.rename(directory, previous) if File.exist?(directory)
        begin
          File.rename(staged, directory)
        rescue SystemCallError
          File.rename(previous, directory) if File.exist?(previous)
          raise
        end
      end
      directory
    end

    # The settings every L4Re build directory reads, from the source's Makeconf.local
    # (mk includes it before the directory's own): the target, the toolchain and the host
    # compilers. They are in place before a directory is created, when mk already checks
    # for its compilers, and image tools, which clear MAKEFLAGS, read them too. The
    # compiler's own freestanding headers (stdbool.h, stdarg.h, ...) come from clang's
    # resource directory, and no libgcc is linked. mk rebuilds everything when this file
    # is newer than its outputs, so unchanged settings keep the previous file's time.
    def write_user_settings(path, previous:)
      settings = "# Generated by erXos.\nCROSS_COMPILE := #{FiascoToolchain::CROSS_COMPILE}\nHOST_CC := #{HostOs::HOST_CC}\nHOST_CXX := #{HostOs::HOST_CXX}\nBOOTSTRAP_CMDLINE := #{KERNEL_OPTIONS}\n" +
                 self.class.make_settings(toolchain.user_settings)
      File.write(path, settings)
      return unless File.file?(previous) && File.read(previous) == settings

      File.utime(File.atime(previous), File.mtime(previous), path)
    end

    def validate_user_source(directory)
      return unless File.exist?(directory) || File.symlink?(directory)
      marker = File.join(directory, '.erx-source.json')
      unless File.directory?(directory) && !File.symlink?(directory) &&
             File.file?(marker) &&
             read_build_record(marker, label: 'Fiasco source assembly record',
                                       remedy: 'recreate build/fiasco/source') ==
               { 'owner' => 'erx-fiasco', 'source' => @source }
        raise Error, 'incomplete or stale Fiasco source assembly; recreate build/fiasco/source'
      end
    end

    def build_boot_cores
      CoreArchive.build_boot(root: @inputs.tree, compiler: @compiler, runner: @runner, project: @root,
                             output: File.join(@build, 'boot-cores'))
    end

    def build_users(jobs:, boot_cores:, directory: File.join(@build, 'users'), config: 'user.defconfig')
      source = assemble_user_source
      configure(source: source, directory: directory,
                input: @inputs.configuration(config),
                output: '.kconfig', name: "fiasco-#{File.basename(directory)}-config")
      @runner.run(['gmake', '-C', directory, "-j#{jobs}", *toolchain_variables,
                   "ERX_BOOT_ARCHIVE=#{boot_cores.archive}", "ERX_BOOT_INCLUDE=#{boot_cores.seam}"],
                  name: "fiasco-#{File.basename(directory)}-build", deadline: 600, env: build_environment)
      directory
    end

    # Both the authoritative input and its resolved output participate in
    # reuse. Editing a generated config cannot silently change the build.
    def configure(source:, directory:, input:, output:, name:)
      marker = File.join(directory, '.erx-config.json')
      resolved = File.join(directory, output)
      expected = { 'source' => source, 'input_sha256' => Digest::SHA256.file(input).hexdigest }
      if File.file?(marker) && File.file?(resolved)
        recorded = read_build_record(marker, label: 'Fiasco configuration record',
                                     remedy: 'recreate the build directory')
        current = expected.merge('resolved_sha256' => Digest::SHA256.file(resolved).hexdigest)
        return if current == recorded
      end
      if File.file?(File.join(directory, 'Makefile'))
        FileUtils.copy_file(input, resolved)
        @runner.run(['gmake', '-C', directory, 'olddefconfig', *toolchain_variables],
                    name: name, deadline: 120, env: build_environment)
      else
        writable_input = build_configuration_copy(input)
        @runner.run(['gmake', '-C', source, "B=#{directory}", "DEFCONFIG=#{writable_input}",
                     *toolchain_variables], name: name, deadline: 120,
                    env: build_environment)
      end
      raise Error, "configuration did not produce #{output}" unless File.file?(resolved)
      File.write(marker, JSON.pretty_generate(expected.merge('resolved_sha256' => Digest::SHA256.file(resolved).hexdigest)) + "\n")
    end

    # A record this tool wrote into the build tree. One that is unreadable,
    # oversized or not valid JSON is damaged or foreign state, which only
    # recreating its directory (the caller's remedy) replaces. A json that
    # cannot read any record is a fault of the host, so it has no remedy here.
    def read_build_record(path, label:, remedy:)
      bytes = BoundedFile.read(path, maximum: BUILD_RECORD_BYTES)
      JsonInput.parse(bytes, max_bytes: BUILD_RECORD_BYTES, label: label)
    rescue JsonInput::Unsupported
      raise
    rescue Error => error
      raise Error, "#{error.message}; #{remedy}"
    end

    # Inherited configuration appends cached tool settings to its copied
    # defconfig. Its writable copy must not change the captured template.
    def build_configuration_copy(input)
      directory = File.join(@build, 'config')
      OutputDirectory.prepare(root: @root, path: directory)
      output = File.join(directory, File.basename(input))
      raise Error, 'Fiasco configuration copy is a symlink' if File.symlink?(output)
      Dir.mktmpdir('.config-', directory) do |temporary|
        staged = File.join(temporary, 'input')
        File.binwrite(staged, BoundedFile.read(input, maximum: FiascoInputs::MAX_FILE))
        File.rename(staged, output)
      end
      output
    end

    def build_image(users:, output: image_path)
      directory = File.join(@build, 'images')
      OutputDirectory.prepare(root: @root, path: directory)
      built = File.join(users, BOOTSTRAP_OBJECTS, 'bootstrap.raw')
      raise Error, 'bootstrap flat image was not produced' unless File.file?(built)

      File.binwrite(output, BoundedFile.read(built, maximum: BootFile::FIRST_STAGE_MAX))
      output
    end

    def build_environment = self.class.build_environment

    # The LLVM toolchain this build runs: one value for every command and record.
    def toolchain
      @toolchain ||= FiascoToolchain.new(compiler: @compiler, linker: @linker)
    end

    # The toolchain as a build directory sees it: the identities of every program it runs,
    # which name their installed releases, and the settings that directory reads.
    def toolchain_identity(settings)
      toolchain.programs.map { |program| BuildMemo.program_identity(program) }.join("\n") +
        self.class.make_settings(settings)
    end

    # The inherited make system's arguments naming the target and the host compilers.
    def toolchain_variables = ["CROSS_COMPILE=#{FiascoToolchain::CROSS_COMPILE}", *self.class.host_variables]

    # Makeconf.local lines setting each of settings, recursively expanded, so a value
    # may name a variable of the inherited make system ($(LD_EMULATION)).
    def self.make_settings(settings) = settings.map { |name, value| "#{name} = #{value}\n" }.join

    # The arguments that name the compilers of the build's host tools, which the inherited
    # rules otherwise take to be `gcc` and `g++` (HostOs::HOST_CC).
    def self.host_variables
      ["HOSTCC=#{HostOs::HOST_CC}", "HOST_CC=#{HostOs::HOST_CC}", "HOST_CXX=#{HostOs::HOST_CXX}"]
    end

    # The build's whole environment: every variable of this process's unset but these.
    def self.build_environment
      ENV.keys.to_h { |name| [name, nil] }.merge('PATH' => program_directories.join(File::PATH_SEPARATOR),
                                                'SOURCE_DATE_EPOCH' => '0',
                                                'LC_ALL' => 'C', 'TZ' => 'UTC',
                                                'TMPDIR' => File.realpath(Dir.tmpdir))
    end

    # The build's PATH: for each of PROGRAMS, found in the absolute directories of this process's PATH, the directory
    # it really lives in; then the operating system's directories. A directory of the
    # caller's PATH reaches the build only as the home of one of those programs, and then
    # the build can run every program in it, which is why memo_key names every program
    # there. The system directories come last whatever a program's home (perl's is
    # /usr/bin on macOS), so a package's program is found ahead of a system program of the
    # same name.
    def self.program_directories
      search = HostPath.directories(ENV.fetch('PATH', ''))
      found = PROGRAMS.map do |program|
        executable = HostPath.find_program(program, directories: search)
        raise Error, "missing #{program}; install it (README.md, \"Host setup\")" unless executable

        File.dirname(File.realpath(executable))
      end
      ((found - BuildMemo::SYSTEM_DIRECTORIES) + BuildMemo::SYSTEM_DIRECTORIES).uniq
    end
  end
end
