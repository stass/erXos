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
require_relative 'boot_file'
require_relative 'json_input'
require_relative 'sources'
require_relative 'fiasco_inputs'
require_relative 'fiasco_config'
require_relative 'core_archive'
require_relative 'stack_proof_run'
require_relative 'glue_imports'
require_relative 'output_directory'
require_relative 'origin'

module Erx
  class Fiasco
    IMPLEMENTATION_SHA256 = Digest::SHA256.file(__FILE__).hexdigest.freeze
    KERNEL_COMMIT = '50bbe8a981199e17865e8553a4eb02c387b339cf'
    CORE_COMMIT = 'e2e2d5af9de7aa0e1df2a25ebadee54488fa4a49'
    # SHA-256 of git archives with no prefix, at the full commits above.
    KERNEL_SHA256 = '80cb4b4db43f18521b859012cb16201d62b3b541c69cdfb2f36f6fa726a8aea5'
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
      src/kern/arm/bsp/qcom
    ].freeze
    CORE_PACKAGES = %w[
      compiler-rt compiler-rt-crt compiler-rt-pure crtn cxx cxx_libc_io
      l4re l4re_c l4sys l4util ldscripts libc libc-headers libc-minimal
      libc_backends libgcc libgcc-crt libgcc-headers libgcc-pure
      libgcc_eh libgcc_eh-headers libgcc_eh-pure libpthread
      libsigma0 libstdc++-headers libstdc++-v3 minimal_l4re sigma0
    ].freeze
    UART_FILES = %w[
      Makefile Control Kconfig.L4 LICENSE.spdx README
      include/Makefile include/io_regblock.h include/poll_timeout_counter.h
      include/ARCH-arm64/asm_access.h
      uart/Makefile uart/include/Makefile
      uart/include/device.h uart/include/uart_base.h uart/include/uart_pl011.h
      uart/src/Makefile uart/src/uart_pl011.cc
    ].freeze
    # Fiasco's own options, which bootstrap passes to the kernel. None: without
    # -serial_esc or -serial_input the kernel leaves the UART's interrupt free
    # for the console driver (docs/design-stopgap.md, "The console").
    KERNEL_OPTIONS = ''
    # Where the inherited build leaves bootstrap's objects and images.
    BOOTSTRAP_OBJECTS = 'pkg/bootstrap/server/src/OBJ-arm64_armv8a-nofpu-plain'
    # Upper bound of a record this tool writes into the build tree.
    BUILD_RECORD_BYTES = 65_536
    # One program of each package the build runs from outside the operating system:
    # GNU make, the cross gcc and binutils, gawk (the inherited Makeconf's AWKP), dtc and,
    # on macOS, GNU coreutils, findutils and sed. The directory each really lives in goes on
    # the build's PATH (program_directories), so the build finds every other program of
    # those packages beside it, and memo_key names every program in those directories.
    PROGRAMS = [*%w[gmake aarch64-elf-gcc aarch64-elf-as gawk dtc],
                *(RUBY_PLATFORM.include?('darwin') ? %w[gcp gfind gsed] : [])].freeze
    # The packages whose plain GNU names (make, cp, find), in their libexec/gnubin, the
    # inherited build expects ahead of the operating system's programs of those names.
    GNU_NAMED = %w[gmake gcp gfind].freeze

    # compiler is the LLVM clang that builds the C17 cores' archive; the
    # resource headers it compiles with must be those the reviewed LLVM
    # profile admits (ToolchainProvenance.llvm).
    def initialize(root:, runner: Runner.new(owner_root: root, log_dir: File.join(root, 'build/logs')),
                   compiler: ENV.fetch('ERX_CLANG', ''))
      @root = File.expand_path(root)
      @runner = runner
      @compiler = compiler
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
      required = %w[kernel mk l4re-core bootstrap libfdt drivers-frst]
      raise Error, 'imported Fiasco source root must not be a symlink' if File.symlink?(@source)
      required.each do |name|
        path = File.join(@source, name)
        raise Error, "missing or external imported Fiasco part: #{name}" unless File.directory?(path) && !File.symlink?(path)
      end
      OutputDirectory.prepare(root: @root, path: @build)
      prepare_source_cache
      # A build whose every input is unchanged since the last finished one, with that
      # build's outputs in place, does nothing (memo_key); make would find nothing to do
      # but takes a minute to find it, and the audit after it would find what it found.
      BuildMemo.new(root: @root).in_place('fiasco', key: memo_key, outputs: memo_outputs) do
        cores = build_cores
        kernel = build_kernel(jobs: jobs, cores: cores)
        boot_cores = build_boot_cores
        users = build_users(jobs: jobs, boot_cores: boot_cores)
        build_image(users: users)
        record_provenance
      end
      image_path
    end

    # The kernel again with a test's defines, in its own directory: for a suite
    # that must hold a window open, which no image but that suite's ever boots.
    # build must have run. A source change discards it, as it does the real one.
    def build_test_kernel(name:, defines:, jobs: 4)
      prepare_source_cache
      cores = build_cores
      directory = File.join(@build, "test-kernel-#{name}")
      # Makeconf.local has no rule that rebuilds on a change, so the record holds the defines too.
      inputs = File.read(File.join(@build, '.erx-inputs.json')) + defines.join(' ')
      marker = File.join(directory, '.erx-test-inputs.json')
      current = File.file?(marker) && File.read(marker) == inputs
      FileUtils.remove_entry(directory) if File.exist?(directory) && !current
      build_kernel(jobs: jobs, cores: cores, directory: directory, defines: defines)
      File.write(marker, inputs)
      File.join(directory, 'fiasco')
    end

    # The first stage as built: bootstrap's flat image, with neither locator
    # field written (docs/design-kernel.md, "The bootable file"). What boots is
    # this with an archive; BootImage writes both forms.
    def image_path
      File.join(@build, 'images/bootstrap.raw')
    end

    # The kernel and sigma0 the recipe packs, once built.
    def kernel_path = File.join(@build, 'kernel/fiasco')
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
    def boot_core_archive = File.join(@build, 'boot-cores', CoreArchive::BOOT_ARCHIVE)

    private

    # What the build reads: every captured input by content (FiascoInputs' record), the
    # Ruby that drives it, the compiler, and the environment it runs in. The build finds
    # programs only on that environment's PATH, which holds the operating system's
    # directories, named by its release, and directories every program of which the key
    # names by identity.
    def memo_key
      environment = build_environment.compact
      programs = environment.fetch('PATH').split(File::PATH_SEPARATOR).reject { |directory| BuildMemo::SYSTEM_DIRECTORIES.include?(directory) }
                            .to_h { |directory| [directory, directory_programs(directory)] }
      BuildMemo.key('inputs' => @captured.fetch('sha256'), 'tools' => BuildMemo.tools_digest(root: @root),
                    'compiler' => BuildMemo.program_identity(@compiler), 'programs' => programs,
                    'system' => BuildMemo.system_release, 'environment' => environment)
    end

    # Every program in directory, by name and identity.
    def directory_programs(directory)
      Dir.children(directory).sort.map { |name| File.join(directory, name) }
         .select { |path| File.file?(path) && File.executable?(path) }
         .to_h { |path| [File.basename(path), BuildMemo.program_identity(path)] }
    end

    # What the build leaves for the image and the native builds, and the receipt that
    # vouches for it: a hit needs each with the bytes the finished build left, the header
    # trees the native compiles include by content (BuildMemo#in_place).
    def memo_outputs
      [image_path, kernel_path, sigma0_path, boot_core_archive, *%w[libgcc.a libsigma0.a libl4sys.p.a].map { |name| user_library(name) },
       *user_include_directories, File.join(@build, 'receipt.json'), File.join(@build, 'provenance.json')]
    end

    def record_provenance
      require_relative 'fiasco_provenance'
      auditor = FiascoProvenance.new(root: @root, runner: @runner,
                                     external: FiascoProvenance.external_registry(root: @root, compiler: @compiler,
                                                                                  runner: @runner),
                                     compiler: @compiler)
      auditor.capture_construction
      report = auditor.audit
      auditor.record_receipt(report)
    end

    # Inherited dependency stamps do not cover every generator's code. A
    # source change therefore discards that component's derived outputs;
    # ordinary incremental work is reused only for the same source bytes.
    def prepare_source_cache
      @inputs = FiascoInputs.new(root: @root)
      captured = @captured = @inputs.prepare
      expected = {
        'kernel' => Digest::SHA256.hexdigest(IMPLEMENTATION_SHA256 + CoreArchive::IMPLEMENTATION_SHA256 +
                                             @inputs.component_id(captured, component: 'kernel')),
        'users' => Digest::SHA256.hexdigest(IMPLEMENTATION_SHA256 + @inputs.component_id(captured, component: 'users'))
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
      changed.each do |name|
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
      FileUtils.remove_entry(File.join(core, 'libc/uclibc-ng'))
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

    def build_kernel(jobs:, cores:, directory: File.join(@build, 'kernel'), defines: [])
      configure(source: @inputs.part('kernel'), directory: directory,
                input: @inputs.configuration('kernel.defconfig'),
                output: 'globalconfig.out', name: 'fiasco-kernel-config')
      # The resolved file, not the defconfig: a select can set an option the
      # defconfig leaves unset.
      FiascoConfig.check(File.join(directory, 'globalconfig.out'))
      # The kernel's Makeconf reads this file from its build directory.
      File.write(File.join(directory, 'Makeconf.local'), "CPPFLAGS += #{defines.join(' ')}\n") unless defines.empty?
      @runner.run(['gmake', '-C', directory, "-j#{jobs}", 'CROSS_COMPILE=aarch64-elf-',
                   "ERX_CORE_ARCHIVE=#{cores.archive}", "ERX_CORE_INCLUDE=#{cores.seam}"],
                  name: 'fiasco-kernel-build', deadline: 600, env: build_environment)
      GlueImports.check(source: @inputs.part('kernel'), allowlist: File.join(@source, GlueImports::ALLOWLIST),
                        objects: directory, runner: @runner, env: build_environment)
      directory
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

    def build_users(jobs:, boot_cores:)
      source = assemble_user_source
      directory = File.join(@build, 'users')
      configure(source: source, directory: directory,
                input: @inputs.configuration('user.defconfig'),
                output: '.kconfig', name: 'fiasco-users-config')
      # Image tools clear MAKEFLAGS when querying the configuration. Keep the
      # compiler prefix in the build's own configuration as well as argv.
      local = File.join(directory, 'Makeconf.local')
      settings = "# Generated by erXos.\nCROSS_COMPILE := aarch64-elf-\nBOOTSTRAP_CMDLINE := #{KERNEL_OPTIONS}\n"
      File.write(local, settings) unless File.file?(local) && File.read(local) == settings
      @runner.run(['gmake', '-C', directory, "-j#{jobs}", 'CROSS_COMPILE=aarch64-elf-',
                   "ERX_BOOT_ARCHIVE=#{boot_cores.archive}", "ERX_BOOT_INCLUDE=#{boot_cores.seam}"],
                  name: 'fiasco-users-build', deadline: 600, env: build_environment)
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
        @runner.run(['gmake', '-C', directory, 'olddefconfig', 'CROSS_COMPILE=aarch64-elf-'],
                    name: name, deadline: 120, env: build_environment)
      else
        writable_input = build_configuration_copy(input)
        @runner.run(['gmake', '-C', source, "B=#{directory}", "DEFCONFIG=#{writable_input}",
                     'CROSS_COMPILE=aarch64-elf-'], name: name, deadline: 120,
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

    def build_image(users:)
      directory = File.join(@build, 'images')
      OutputDirectory.prepare(root: @root, path: directory)
      built = File.join(users, BOOTSTRAP_OBJECTS, 'bootstrap.raw')
      raise Error, 'bootstrap flat image was not produced' unless File.file?(built)

      File.binwrite(image_path, BoundedFile.read(built, maximum: BootFile::FIRST_STAGE_MAX))
      image_path
    end

    def build_environment
      self.class.build_environment
    end

    # The build's whole environment: every variable of this process's unset but these.
    def self.build_environment
      ENV.keys.to_h { |name| [name, nil] }.merge('PATH' => program_directories.join(File::PATH_SEPARATOR), 'SOURCE_DATE_EPOCH' => '0',
                                                'LC_ALL' => 'C', 'TZ' => 'UTC',
                                                'TMPDIR' => File.realpath(Dir.tmpdir))
    end

    # The build's PATH: for each of PROGRAMS, found on this process's PATH, the directory
    # it really lives in, after its package's GNU names (GNU_NAMED); then the operating
    # system's directories. Nothing else on the caller's PATH reaches the build, so it
    # runs no program memo_key does not name.
    def self.program_directories
      search = ENV.fetch('PATH', '').split(File::PATH_SEPARATOR)
      found = PROGRAMS.flat_map do |program|
        executable = search.map { |directory| File.join(directory, program) }
                           .find { |candidate| File.file?(candidate) && File.executable?(candidate) }
        raise Error, "missing #{program}; install it with Homebrew (README.md)" unless executable

        bin = File.dirname(File.realpath(executable))
        gnu = File.expand_path('../libexec/gnubin', bin)
        GNU_NAMED.include?(program) && File.directory?(gnu) ? [gnu, bin] : [bin]
      end
      (found + BuildMemo::SYSTEM_DIRECTORIES).uniq
    end
  end
end
