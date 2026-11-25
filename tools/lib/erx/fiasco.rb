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
    # The boards whose bootstrap is a build of its own, by platform record name, and the
    # configuration of each (docs/design-fiasco.md, "The Raspberry Pi 4"). The Pi's is
    # Fiasco's generic platform, linked static at 2 MiB, with RAM at 0 and the mini UART's
    # 16550 driver; QEMU virt's is the main build's (user.defconfig).
    BOARD_BOOTSTRAPS = { 'raspi4b' => 'user-raspi4b.defconfig' }.freeze
    # The directory under build/fiasco a board's own bootstrap is built in.
    def self.board_users(name) = "users-#{name}"
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
    # every image is a development build (ProductionImage::BUILD_KIND).
    #
    # The release's link audit (FiascoProvenance#certify) reads every executable a boot
    # image carries and must find every source they link under terms a release may carry,
    # or the build fails naming each source that is not. Those executables are the
    # development build's and each board's own bootstrap, so both are built here first;
    # build does nothing when its inputs are unchanged.
    #
    # The kernel stays only beside the audit's pass record: an earlier record goes before
    # any build, and a build that fails anywhere removes the kernel and any record.
    def build_release_kernel(jobs: 4)
      require_relative 'fiasco_provenance'
      directory = self.class.kernel_directory(root: @root, kind: BuildKind::RELEASE)
      kernel = File.join(directory, 'fiasco')
      record = File.join(directory, FiascoProvenance::PASS_RECORD)
      FileUtils.rm_f(record)
      passed = false
      build(jobs: jobs)
      with_tree_lock do
        build_kernel_beside(directory: directory, kind: BuildKind::RELEASE, defines: [], jobs: jobs)
        BOARD_BOOTSTRAPS.each_key { |name| build_board_users(name, jobs: jobs) }
        provenance_auditor(kind: BuildKind::RELEASE).certify
      end
      passed = true
      kernel
    ensure
      FileUtils.rm_f([kernel, record]) unless passed
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
      raise Error, "platform #{name} has no bootstrap build of its own" unless BOARD_BOOTSTRAPS.key?(name)
      raise Error, 'jobs must be between 1 and 64' unless jobs.is_a?(Integer) && jobs.between?(1, 64)

      with_tree_lock do
        build_image(users: build_board_users(name, jobs: jobs), output: board_image_path(name))
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
      users = BOARD_BOOTSTRAPS.key?(platform.name) ? self.class.board_users(platform.name) : 'users'
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
        'kernel' => Digest::SHA256.hexdigest(IMPLEMENTATION_SHA256 + CoreArchive::IMPLEMENTATION_SHA256 + toolchain_identity(kernel_makeconf) +
                                             @inputs.component_id(captured, component: 'kernel')),
        'users' => Digest::SHA256.hexdigest(IMPLEMENTATION_SHA256 + toolchain_identity(user_makeconf) + @inputs.component_id(captured, component: 'users'))
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
      discarded = changed.flat_map { |name| name == 'users' ? ['users', *BOARD_BOOTSTRAPS.keys.map { |board| self.class.board_users(board) }] : [name] }
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
      settings = kernel_makeconf.merge(defines.empty? ? {} : { 'CPPFLAGS' => defines })
      File.write(File.join(directory, 'Makeconf.local'), self.class.make_settings(settings))
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
        write_user_makeconf(File.join(staged, 'Makeconf.local'), previous: File.join(directory, 'Makeconf.local'))
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
    def write_user_makeconf(path, previous:)
      settings = "# Generated by erXos.\nCROSS_COMPILE := #{FiascoToolchain::CROSS_COMPILE}\nHOST_CC := #{HostOs::HOST_CC}\nHOST_CXX := #{HostOs::HOST_CXX}\nBOOTSTRAP_CMDLINE := #{KERNEL_OPTIONS}\n" +
                 self.class.make_settings(user_makeconf)
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

    # The users' build of a board's own bootstrap (BOARD_BOOTSTRAPS), in board_users(name).
    def build_board_users(name, jobs:)
      prepare_source_cache
      build_users(jobs: jobs, boot_cores: build_boot_cores,
                  directory: File.join(@build, self.class.board_users(name)), config: BOARD_BOOTSTRAPS.fetch(name))
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

    # The kernel build directory's Makeconf.local: the toolchain's settings, and the
    # checkout's path maps, which SHARED_FLAGS takes to every C, C++ and assembly
    # compile and PREPROCESS_FLAGS to the #line directives of the sources preprocess
    # generates, whose bytes the compiler's DWARF 5 line table records as an MD5
    # checksum. preprocess, like the compiler, gets every spelling of the checkout.
    def kernel_makeconf
      { **toolchain.kernel_settings, 'SHARED_FLAGS' => file_prefix_maps,
        'PREPROCESS_FLAGS' => FiascoToolchain.checkout_names(@root).map { |name| "-m #{name}=." } }
    end

    # L4Re's build directories' Makeconf.local: the toolchain's settings, and the
    # checkout's path maps, which CCXX_FLAGS takes to every target C and C++ compile.
    # mk's own maps, which its assembly compiles take too, cover its source and object
    # directories.
    def user_makeconf = { **toolchain.user_settings, 'CCXX_FLAGS' => file_prefix_maps }

    # Flags, added to the inherited make systems' own, that write every path under the
    # checkout into an object (debug information, __FILE__) relative to it, so the
    # Fiasco build's bytes do not depend on where the tree is checked out. The inherited
    # maps cover only each build's source and object directories, and the kernel's only
    # for GCC, while the erXos cores' headers are elsewhere in the checkout. Dependency
    # files, which the provenance audit reads, keep real paths.
    def file_prefix_maps = FiascoToolchain.checkout_names(@root).map { |name| "-ffile-prefix-map=#{name}=." }

    # The toolchain as a build directory sees it: the identities of every program it runs,
    # which name their installed releases, and the settings that directory reads.
    def toolchain_identity(settings)
      toolchain.programs.map { |program| BuildMemo.program_identity(program) }.join("\n") +
        self.class.make_settings(settings)
    end

    # The inherited make system's arguments naming the target and the host compilers.
    def toolchain_variables = ["CROSS_COMPILE=#{FiascoToolchain::CROSS_COMPILE}", *self.class.host_variables]

    # Makeconf.local lines setting each of settings, recursively expanded, so a value
    # may name a variable of the inherited make system ($(LD_EMULATION)). A list of
    # flags is added to the variable's inherited value rather than replacing it.
    def self.make_settings(settings)
      settings.map do |name, value|
        case value
        in Array then "#{name} += #{value.join(' ')}\n"
        in String then "#{name} = #{value}\n"
        end
      end.join
    end

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
