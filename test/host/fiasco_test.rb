# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'minitest/autorun'
require 'tmpdir'
require 'rubygems/package'
require 'stringio'
require 'zlib'
require_relative '../../tools/lib/erx/fiasco'
require_relative '../../tools/lib/erx/fiasco_provenance'

class FiascoTest < Minitest::Test
  # The recording runner resolves a configuration by copying it, so the
  # fixture is already in the shape the configuration check accepts.
  KERNEL_CONFIG = "CONFIG_ARM=y\n# CONFIG_CPU_VIRT is not set\nCONFIG_FPU=y\nCONFIG_SYNC_CLOCK=y\n" \
                  "CONFIG_BENCHMARKING=y\nCONFIG_PERF_CNT_USER=y\n"

  def test_build_environment_supplies_the_host_temporary_directory
    assert_equal File.realpath(Dir.tmpdir), Erx::Fiasco.build_environment.fetch('TMPDIR')
  end
  # These tests exercise orchestration with a recording runner. Native build
  # integration exercises the real provenance/replay boundary.
  class FixtureBuild < Erx::Fiasco
    private

    def record_provenance
      nil
    end

    # The release kernel's license check is the link audit's, which
    # fiasco_provenance_test.rb covers; here it accepts every kernel.
    AcceptingAudit = Data.define do
      def certify = nil
    end

    def provenance_auditor(kind:) = AcceptingAudit.new

    # The cores' archive has its own tests (core_archive_test.rb); here it
    # is a fixed result whose paths the kernel make must receive.
    def build_boot_cores
      Erx::CoreArchive::Built.new(archive: File.join(@build, %q(boot-cores/erx_boot.a)), objects: {},
                                  seam: File.join(@build, %q(boot-cores/seam)))
    end

    def build_cores
      Erx::CoreArchive::Built.new(archive: File.join(@build, 'cores/erx_cores.a'), objects: {},
                                  seam: File.join(@build, 'cores/seam'))
    end
  end
  def test_build_environment_explicitly_removes_ambient_image_hooks
    previous = ENV['L4IMAGE_EXTRA_OPTS']
    ENV['L4IMAGE_EXTRA_OPTS'] = '--unreviewed-hook'
    environment = Erx::Fiasco.new(root: Dir.pwd).send(:build_environment)
    assert environment.key?('L4IMAGE_EXTRA_OPTS')
    assert_nil environment.fetch('L4IMAGE_EXTRA_OPTS')
  ensure
    ENV['L4IMAGE_EXTRA_OPTS'] = previous
  end
  class RecordingRunner
    attr_reader :commands

    def initialize
      @commands = []
    end

    def run(argv, **options)
      @commands << { argv: argv, options: options }
      build_argument = argv.find { |argument| argument.start_with?('B=') }
      if build_argument
        directory = build_argument.delete_prefix('B=')
        FileUtils.mkdir_p(directory)
        File.write(File.join(directory, 'Makefile'), '# inherited build redirect')
        config = argv.find { |argument| argument.start_with?('DEFCONFIG=') }
        name = argv[2].end_with?('/kernel') ? 'globalconfig.out' : '.kconfig'
        FileUtils.copy_file(config.delete_prefix('DEFCONFIG='), File.join(directory, name))
      end
      if options.fetch(:name) == 'fiasco-users-build'
        users = argv.fetch(argv.index('-C') + 1)
        generated = File.join(users, 'module-data')
        source = File.join(File.dirname(users), 'source/Makefile')
        File.write(generated, File.read(source)) unless File.file?(generated)
        flat = File.join(users, Erx::Fiasco::BOOTSTRAP_OBJECTS, 'bootstrap.raw')
        FileUtils.mkdir_p(File.dirname(flat))
        File.write(flat, File.read(generated))
      end
      { 'state' => 'succeeded' }
    end
  end

  def setup
    @directory = Dir.mktmpdir('erx-fiasco-')
    @runner = RecordingRunner.new
    @fiasco = FixtureBuild.new(root: @directory, runner: @runner, **fixture_toolchain('toolchain'))
    %w[kernel mk l4re-core bootstrap libfdt drivers-frst].each do |name|
      FileUtils.mkdir_p(File.join(@directory, 'fiasco', name))
    end
    Erx::CoreArchive::READ_DIRECTORIES.each do |name|
      FileUtils.mkdir_p(File.join(@directory, name))
    end
    Erx::FiascoInputs::ERXOS_FILES.each do |name|
      FileUtils.mkdir_p(File.dirname(File.join(@directory, name)))
      File.write(File.join(@directory, name), "/* fixture */\n")
    end
    File.write(File.join(@directory, 'fiasco/mk/Makefile'), '# inherited')
    FileUtils.mkdir_p(File.join(@directory, 'config/fiasco'))
    File.write(kernel_config, KERNEL_CONFIG)
    File.write(user_config, "CONFIG_BUILD_ARCH_arm64=y\n")
    File.write(File.join(@directory, 'config/fiasco/user-raspi4b.defconfig'), "CONFIG_BUILD_ARCH_arm64=y\n")
    File.write(File.join(@directory, 'config/fiasco/modules.list'), 'fixture')
    File.write(File.join(@directory, 'fiasco/erx_glue_imports.txt'), "# no glue in this fixture\n")
  end

  def teardown
    FileUtils.remove_entry(@directory)
  end

  def kernel_config
    File.join(@directory, 'config/fiasco/kernel.defconfig')
  end

  def user_config
    File.join(@directory, 'config/fiasco/user.defconfig')
  end

  def test_build_wraps_inherited_offline_commands
    assert_equal @fiasco.image_path, @fiasco.build(jobs: 3)
    assert @runner.commands.all? { |command| command.fetch(:argv).first == 'gmake' }
    assert @runner.commands.all? { |command| command.fetch(:options).fetch(:deadline).positive? }
    users = @runner.commands.find { |command| command.fetch(:options).fetch(:name) == 'fiasco-users-build' }
    boot_cores = File.join(@directory, 'build/fiasco/boot-cores')
    assert_includes users.fetch(:argv), "ERX_BOOT_ARCHIVE=#{boot_cores}/erx_boot.a"
    assert_includes users.fetch(:argv), "ERX_BOOT_INCLUDE=#{boot_cores}/seam"
    kernel = @runner.commands.find { |command| command.fetch(:options).fetch(:name) == 'fiasco-kernel-build' }
    cores = File.join(@directory, 'build/fiasco/cores')
    assert_includes kernel.fetch(:argv), "ERX_CORE_ARCHIVE=#{cores}/erx_cores.a"
    assert_includes kernel.fetch(:argv), "ERX_CORE_INCLUDE=#{cores}/seam"
    assert_includes users.fetch(:argv), "CROSS_COMPILE=#{Erx::FiascoToolchain::CROSS_COMPILE}"
    Erx::Fiasco.host_variables.each { |variable| assert_includes users.fetch(:argv), variable }
    %w[HOSTCC HOST_CC HOST_CXX].each { |name| assert(users.fetch(:argv).any? { |argument| argument.start_with?("#{name}=") }) }
  end

  def test_kernel_uses_recorded_private_inputs_and_rejects_later_repository_edits
    source = File.join(@directory, 'fiasco/kernel/banner.cpp')
    File.write(source, "// Modified by erXos\nint banner;\n")
    @fiasco.build
    configure = @runner.commands.find { |command| command.fetch(:options).fetch(:name) == 'fiasco-kernel-config' }
    private_source = configure.fetch(:argv).fetch(2)
    assert private_source.start_with?(File.join(File.realpath(@directory), 'build/fiasco/inputs/'))
    assert_equal File.binread(source), File.binread(File.join(private_source, 'banner.cpp'))
    File.write(source, "// Modified by erXos\nint changed_banner;\n")
    assert_raises(Erx::Error) { Erx::FiascoInputs.new(root: @directory).verify }
  end

  def test_inherited_configuration_gets_a_writable_copy_of_captured_settings
    @fiasco.build
    @runner.commands.select { |command| command.fetch(:argv).any? { |argument| argument.start_with?('B=') } }.each do |command|
      path = command.fetch(:argv).find { |argument| argument.start_with?('DEFCONFIG=') }.delete_prefix('DEFCONFIG=')
      refute_equal 0, File.stat(path).mode & 0o200
    end
  end

  def test_changed_kernel_config_is_applied_to_incremental_build
    @fiasco.build
    changed = File.read(kernel_config) + "CONFIG_MP_MAX_CPUS=4\n"
    File.write(kernel_config, changed)
    @fiasco.build
    assert_equal changed, File.read(File.join(@directory, 'build/fiasco/kernel/globalconfig.out'))
  end

  # The check runs before the kernel make on every kernel build, also the
  # second one here, which reuses its configuration step.
  def test_resolved_kernel_config_breaking_the_forks_rules_stops_the_build
    File.write(kernel_config, KERNEL_CONFIG + "CONFIG_LAZY_FPU=y\n")
    2.times do
      @runner.commands.clear
      error = assert_raises(Erx::Error) { @fiasco.build }
      assert_includes error.message, 'CONFIG_LAZY_FPU must be unset'
      refute(@runner.commands.any? { |command| command.fetch(:options).fetch(:name) == 'fiasco-kernel-build' })
    end
    refute(@runner.commands.any? { |command| command.fetch(:options).fetch(:name) == 'fiasco-kernel-config' })
  end

  # The release kernel is configured from the development defconfig with the
  # debugger and console input written as not set, in a directory of its own,
  # beside the development kernel's. The development build and each board's own
  # bootstrap are built first, since the release's audit reads them: after a
  # source change the development build's outputs are gone until it runs again.
  def test_release_kernel_is_configured_from_the_development_defconfig_without_the_debugger
    path = @fiasco.build_release_kernel(jobs: 2)
    directory = Erx::Fiasco.kernel_directory(root: @directory, kind: Erx::BuildKind::RELEASE)
    assert_equal File.join(directory, 'fiasco'), path
    assert_equal "#{KERNEL_CONFIG}# CONFIG_JDB is not set\n# CONFIG_INPUT is not set\n",
                 File.read(File.join(directory, 'globalconfig.out'))
    development = Erx::Fiasco.kernel_directory(root: @directory, kind: Erx::BuildKind::DEVELOPMENT)
    assert_equal KERNEL_CONFIG, File.read(File.join(development, 'globalconfig.out'))
    names = @runner.commands.map { |command| command.fetch(:options).fetch(:name) }
    assert_includes names, 'fiasco-users-build'
    assert_includes names, 'fiasco-kernel-release-build'
    assert_operator names.index('fiasco-users-build'), :<, names.index('fiasco-kernel-release-build')
    assert_includes names, 'fiasco-users-raspi4b-config'
  end

  # A release kernel stays only beside its pass record: an earlier record goes
  # before the build, and a kernel whose audit fails is removed with it.
  def test_a_refused_release_kernel_is_removed_with_any_pass_record
    directory = Erx::Fiasco.kernel_directory(root: @directory, kind: Erx::BuildKind::RELEASE)
    record = File.join(directory, Erx::FiascoProvenance::PASS_RECORD)
    FileUtils.mkdir_p(directory)
    File.write(record, 'an earlier pass')
    @fiasco.build_release_kernel(jobs: 2)
    refute File.exist?(record)
    File.write(File.join(directory, 'fiasco'), 'refused kernel')
    File.write(record, 'an earlier pass')
    refusing = Object.new
    refusing.define_singleton_method(:certify) { raise Erx::Error, 'the kernel links sources a release may not carry' }
    original = @fiasco.method(:provenance_auditor)
    @fiasco.define_singleton_method(:provenance_auditor) do |kind:|
      Erx::BuildKind.development?(kind) ? original.call(kind: kind) : refusing
    end
    assert_raises(Erx::Error) { @fiasco.build_release_kernel(jobs: 2) }
    refute File.exist?(File.join(directory, 'fiasco'))
    refute File.exist?(record)
  end

  # Seeded fault: a development defconfig that turns the debugger on would
  # leave it on in the release kernel; that build stops before any make.
  def test_release_kernel_refuses_a_development_defconfig_naming_the_debugger
    File.write(kernel_config, KERNEL_CONFIG + "CONFIG_JDB=y\n")
    error = assert_raises(Erx::Error) { @fiasco.build_release_kernel }
    assert_includes error.message, 'CONFIG_JDB'
    refute(@runner.commands.any? { |command| command.fetch(:options).fetch(:name).start_with?('fiasco-kernel-release') })
  end

  # The case a `select` produces: the resolved release configuration has
  # console input on although the derived defconfig says it is not set.
  class SelectingRunner < RecordingRunner
    def run(argv, **options)
      result = super
      if options.fetch(:name) == 'fiasco-kernel-release-config'
        directory = argv.find { |argument| argument.start_with?('B=') }.delete_prefix('B=')
        resolved = File.join(directory, 'globalconfig.out')
        File.write(resolved, File.read(resolved).sub("# CONFIG_INPUT is not set\n", "CONFIG_INPUT=y\n"))
      end
      result
    end
  end

  # Seeded fault: the build checks the release kernel's resolved file with the
  # release rules and stops before the kernel make.
  def test_release_kernel_whose_resolved_configuration_has_input_stops_the_build
    runner = SelectingRunner.new
    fiasco = FixtureBuild.new(root: @directory, runner: runner, **fixture_toolchain('toolchain'))
    error = assert_raises(Erx::FiascoConfig::Violation) { fiasco.build_release_kernel }
    assert_includes error.message, 'CONFIG_INPUT must be unset'
    refute(runner.commands.any? { |command| command.fetch(:options).fetch(:name) == 'fiasco-kernel-release-build' })
  end

  def test_changed_user_config_is_applied_to_incremental_build
    @fiasco.build
    changed = File.read(user_config) + "CONFIG_DRIVERS_FRST_UART_DRV_PL011=y\n"
    File.write(user_config, changed)
    @fiasco.build
    assert_equal changed, File.read(File.join(@directory, 'build/fiasco/users/.kconfig'))
  end

  def test_partial_derived_source_tree_is_not_accepted
    FileUtils.mkdir_p(File.join(@directory, 'build/fiasco/source'))
    assert_raises(Erx::Error) { @fiasco.build }
  end

  def test_generator_change_cannot_reuse_previous_module_data
    @fiasco.build
    File.write(File.join(@directory, 'fiasco/mk/Makefile'), '# changed generator')
    @fiasco.build
    assert_equal '# changed generator', File.read(@fiasco.image_path)
  end

  def test_malformed_source_cache_record_is_refused
    FileUtils.mkdir_p(File.join(@directory, 'build/fiasco'))
    File.write(File.join(@directory, 'build/fiasco/.erx-inputs.json'),
               JSON.generate('kernel' => 3, 'users' => 4))
    assert_raises(Erx::Error) { @fiasco.build }
    assert_empty @runner.commands
  end

  def test_imported_part_must_not_be_an_external_symlink
    path = File.join(@directory, 'fiasco/kernel')
    FileUtils.remove_entry(path)
    external = File.join(@directory, 'external')
    Dir.mkdir(external)
    File.symlink(external, path)
    assert_raises(Erx::Error) { @fiasco.build }
    assert_empty @runner.commands
  end

  def test_invalid_parallelism_is_refused_before_commands
    assert_raises(Erx::Error) { @fiasco.build(jobs: 0) }
    assert_empty @runner.commands
  end

  # A build whose PATH the test sets, standing for the programs the build may run.
  class PathBuild < FixtureBuild
    attr_accessor :programs

    private

    def build_environment = super.merge('PATH' => [programs, *Erx::BuildMemo::SYSTEM_DIRECTORIES].join(File::PATH_SEPARATOR))
  end

  # Empty executable stand-ins for clang and ld.lld under @directory/name, since the
  # toolchain refuses a program that is not there: the keywords that name them.
  def fixture_toolchain(name)
    { compiler: 'llvm/bin/clang', linker: 'lld/bin/ld.lld' }.transform_values do |relative|
      path = File.join(@directory, name, relative)
      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, '')
      File.chmod(0o755, path)
      File.realpath(path)
    end
  end

  def commands_of_a_build(fiasco = @fiasco)
    before = @runner.commands.size
    fiasco.build
    @runner.commands.size - before
  end

  # The build after an unchanged one runs no command on a host that reuses records
  # (BuildMemo::REUSE) and all of them again on a host that does not.
  def assert_second_build(fiasco = @fiasco)
    commands = commands_of_a_build(fiasco)
    if Erx::BuildMemo::REUSE
      assert_equal 0, commands, 'an unchanged build is reused'
    else
      assert commands.positive?, 'a host that reuses no record runs the build again'
    end
  end

  def test_a_finished_build_is_reused_until_an_input_changes
    assert commands_of_a_build.positive?
    assert_second_build
    File.write(File.join(@directory, 'fiasco/kernel/extra.cpp'), "int extra;\n")
    assert commands_of_a_build.positive?
  end

  def test_every_program_on_the_build_path_is_an_input
    fiasco = PathBuild.new(root: @directory, runner: @runner, **fixture_toolchain('toolchain'))
    fiasco.programs = File.join(@directory, 'programs')
    FileUtils.mkdir_p(fiasco.programs)
    tool = File.join(fiasco.programs, 'tool')
    File.write(tool, "#!/bin/sh\n")
    File.chmod(0o755, tool)
    assert commands_of_a_build(fiasco).positive?
    assert_second_build(fiasco)
    File.write(tool, "#!/bin/sh\nexit 0\n")
    assert commands_of_a_build(fiasco).positive?, 'a changed program builds again'
    other = File.join(fiasco.programs, 'other')
    File.write(other, "#!/bin/sh\n")
    File.chmod(0o755, other)
    assert commands_of_a_build(fiasco).positive?, 'a program added beside the others builds again'
  end

  # The toolchain is an input: a build with another LLVM runs again, and both
  # build directories' Makeconf.local name its programs, since a CC on the make
  # command line would drop the target flag the inherited make systems add.
  def test_another_toolchain_builds_again_with_that_toolchain
    assert commands_of_a_build.positive?
    assert_second_build
    local = File.join(@directory, 'build/fiasco/source/Makeconf.local')
    File.utime(Time.at(0), Time.at(0), local)
    assert_second_build
    assert_equal Time.at(0), File.mtime(local), 'unchanged settings keep their time, which mk rebuilds everything after'
    # A board's L4Re directory reads the same settings, so it goes with the main one.
    board = File.join(@directory, 'build/fiasco/users-raspi4b')
    FileUtils.mkdir_p(board)
    fiasco = FixtureBuild.new(root: @directory, runner: @runner, **fixture_toolchain('other'))
    other = File.realpath(File.join(@directory, 'other'))
    assert commands_of_a_build(fiasco).positive?
    kernel = File.read(File.join(@directory, 'build/fiasco/kernel/Makeconf.local'))
    assert_includes kernel, "CC = #{other}/llvm/bin/clang\nCXX = #{other}/llvm/bin/clang++\nCPP = #{other}/llvm/bin/clang-cpp\n"
    assert_includes kernel, "LD = #{other}/lld/bin/ld.lld\n"
    assert_includes kernel, "OBJCOPY = #{other}/llvm/bin/llvm-objcopy\n"
    # llvm-ar reads the inherited crsUT as a thin archive, which the link audit refuses,
    # and U as a request for member timestamps and owners, which differ between builds.
    assert_includes kernel, "ARFLAGS = crs\n"
    # Every compile maps the checkout, by each of its spellings, to '.', so no path of
    # the checkout reaches an object or archive and two checkouts build the same bytes.
    map = [@directory, File.realpath(@directory)].uniq.map { |root| "-ffile-prefix-map=#{root}=." }.join(' ')
    assert_includes kernel, "SHARED_FLAGS += #{map}\n"
    refute File.exist?(board), 'a toolchain change discards the board build directories'
    users = File.read(File.join(@directory, 'build/fiasco/source/Makeconf.local'))
    assert_includes users, "CROSS_COMPILE := #{Erx::FiascoToolchain::CROSS_COMPILE}\n"
    assert_includes users, "HOST_CC := #{Erx::HostOs::HOST_CC}\nHOST_CXX := #{Erx::HostOs::HOST_CXX}\n"
    assert_includes users, "CLANG = #{other}/llvm/bin/\nLD = #{other}/lld/bin/ld.lld -m $(LD_EMULATION)\n"
    assert_includes users, "CCXX_FLAGS += #{map}\n"
    refute_includes users, 'LIBGCC'
    makes = @runner.commands.select { |command| command.fetch(:argv).first == 'gmake' }
    refute(makes.any? { |command| command.fetch(:argv).any? { |argument| argument.start_with?('CC=', 'LD=', 'CLANG=') } })
  end

  # However the environment spells it, the toolchain names the installed programs, and
  # ld.lld keeps the name the multi-call lld acts on.
  def test_a_toolchain_names_its_installed_programs
    Dir.mktmpdir do |temporary|
      root = File.realpath(temporary)
      FileUtils.mkdir_p(%w[llvm/bin lld/bin links].map { |path| File.join(root, path) })
      %w[llvm/bin/clang-23 lld/bin/lld].each do |program|
        File.write(File.join(root, program), '')
        File.chmod(0o755, File.join(root, program))
      end
      File.symlink('lld', File.join(root, 'lld/bin/ld.lld'))
      File.symlink(File.join(root, 'llvm/bin/clang-23'), File.join(root, 'links/clang'))
      File.symlink(File.join(root, 'lld/bin/ld.lld'), File.join(root, 'links/ld.lld'))
      linked = Erx::FiascoToolchain.new(compiler: File.join(root, 'links/clang'), linker: File.join(root, 'links/ld.lld'))
      real = Erx::FiascoToolchain.new(compiler: File.join(root, 'llvm/bin/clang-23'), linker: File.join(root, 'lld/bin/ld.lld'))
      assert_equal real, linked
      assert_equal File.join(root, 'lld/bin/ld.lld'), linked.linker
      assert_equal File.join(root, 'llvm/bin/llvm-nm'), linked.program('nm')
    end
  end

  def test_a_toolchain_needs_clang_and_lld
    error = assert_raises(Erx::Error) { Erx::FiascoToolchain.new(compiler: '/llvm/bin/clang', linker: '') }
    assert_includes error.message, 'ERX_LLD'
  end

  # The checkout's path goes into the flags make hands the shell, so a root with a
  # character make or the shell gives a meaning is refused, not passed on.
  def test_a_checkout_path_make_cannot_take_is_refused
    toolchain = Erx::FiascoToolchain.new(**fixture_toolchain('roots'))
    ['/a b', '/a$(b)', "/a\nb", '/a;b'].each do |root|
      %i[kernel_settings user_settings].each do |settings|
        error = assert_raises(Erx::Error) { toolchain.public_send(settings, root: root) }
        assert_includes error.message, 'checkout', root
      end
    end
  end

  # A bare ERX_LLD is found as every other build finds it: beside clang, then on PATH.
  # A program that is not there is refused by name rather than left for make to fail on.
  def test_a_bare_linker_name_is_found_beside_clang_then_on_path
    tools = fixture_toolchain('beside')
    beside = File.join(File.dirname(tools.fetch(:compiler)), 'ld.lld')
    FileUtils.cp(tools.fetch(:linker), beside, preserve: true)
    assert_equal beside, Erx::FiascoToolchain.new(compiler: tools.fetch(:compiler), linker: 'ld.lld', path: '').linker
    elsewhere = fixture_toolchain('elsewhere')
    clang = File.join(@directory, 'alone/clang')
    FileUtils.mkdir_p(File.dirname(clang))
    FileUtils.cp(tools.fetch(:compiler), clang, preserve: true)
    toolchain = Erx::FiascoToolchain.new(compiler: clang, linker: 'ld.lld', path: "relative:#{File.dirname(elsewhere.fetch(:linker))}")
    assert_equal elsewhere.fetch(:linker), toolchain.linker
    { 'ld.lld' => 'ERX_LLD', File.join(@directory, 'none/ld.lld') => 'ERX_LLD' }.each do |linker, variable|
      error = assert_raises(Erx::Error) { Erx::FiascoToolchain.new(compiler: clang, linker: linker, path: '') }
      assert_includes error.message, variable, linker
    end
    error = assert_raises(Erx::Error) { Erx::FiascoToolchain.new(compiler: File.join(@directory, 'none/clang'), linker: 'ld.lld') }
    assert_includes error.message, 'ERX_CLANG'
  end

  # ld.lld keeps its name beside the program its link resolves to; a link that resolves
  # to a directory holding no program of that name is refused by that name.
  def test_a_linker_link_with_no_program_of_its_name_beside_its_target_is_refused
    tools = fixture_toolchain('multicall')
    lld = File.join(File.dirname(tools.fetch(:linker)), 'lld')
    File.rename(tools.fetch(:linker), lld)
    link = File.join(@directory, 'multicall/links/ld.lld')
    FileUtils.mkdir_p(File.dirname(link))
    File.symlink(lld, link)
    error = assert_raises(Erx::Error) { Erx::FiascoToolchain.new(compiler: tools.fetch(:compiler), linker: link) }
    assert_includes error.message, File.join(File.dirname(lld), 'ld.lld')
  end

  # The ld.lld beside the program a link resolves to must be that program: one that is
  # another executable is refused, not run in place of the linker the environment chose.
  def test_a_linker_whose_name_beside_its_target_is_another_program_is_refused
    tools = fixture_toolchain('impostor')
    lld = File.join(File.dirname(tools.fetch(:linker)), 'lld')
    File.rename(tools.fetch(:linker), lld)
    File.write(tools.fetch(:linker), "#!/bin/sh\n")
    File.chmod(0o755, tools.fetch(:linker))
    link = File.join(@directory, 'impostor/links/ld.lld')
    FileUtils.mkdir_p(File.dirname(link))
    File.symlink(lld, link)
    error = assert_raises(Erx::Error) { Erx::FiascoToolchain.new(compiler: tools.fetch(:compiler), linker: link) }
    assert_includes error.message, tools.fetch(:linker)
    assert_includes error.message, 'is not'
  end

  # Makeconf.local takes the paths as make assignments and the inherited make systems
  # pass them on to the shell, so only characters neither treats specially are taken:
  # anything else is refused before any settings are written.
  def test_a_toolchain_path_make_cannot_take_is_refused
    ['llvm 23', "llvm\n23", 'llvm#23', 'llvm$23', 'llvm;23', 'llvm`23', 'llvm"23', "llvm'23",
     'llvm(23', 'llvm23\\'].each do |name|
      tools = fixture_toolchain(name)
      error = assert_raises(Erx::Error, name.inspect) { Erx::FiascoToolchain.new(**tools) }
      assert_includes error.message, 'make cannot take', name.inspect
    end
  end

  def test_the_user_headers_are_outputs_of_the_build
    header = File.join(@directory, 'build/fiasco/users/include/l4/sys/consts.h')
    assert commands_of_a_build.positive?
    FileUtils.mkdir_p(File.dirname(header))
    File.write(header, "#define L4 1\n")
    assert commands_of_a_build.positive?, 'headers the last build did not leave build again'
    assert_second_build
    File.write(header, "#define L4 2\n")
    assert commands_of_a_build.positive?, 'an edited header builds again'
  end

  def test_the_build_path_holds_only_program_directories_and_the_system
    path = Erx::Fiasco.build_environment.fetch('PATH').split(File::PATH_SEPARATOR)
    packages = path - Erx::BuildMemo::SYSTEM_DIRECTORIES
    assert packages.all? { |directory| directory == File.realpath(directory) }, packages.inspect
    # Each directory is the real home of a program the build names (FreeBSD's /usr/local/bin
    # is one, though the caller's PATH names it too), and memo_key names every program in it.
    caller_path = Erx::HostPath.directories(ENV.fetch('PATH'))
    homes = Erx::Fiasco::PROGRAMS.map do |program|
      File.dirname(File.realpath(Erx::HostPath.find_program(program, directories: caller_path)))
    end
    assert_empty packages - homes
    assert_equal Erx::BuildMemo::SYSTEM_DIRECTORIES, path.last(Erx::BuildMemo::SYSTEM_DIRECTORIES.size)
  end

  # The build's PATH when a directory holding only the executable name sits ahead of the
  # caller's own PATH, and that directory.
  def build_path_with_only(name)
    directory = File.realpath(Dir.mktmpdir(name, @directory))
    File.write(File.join(directory, name), "#!/bin/sh\n")
    File.chmod(0o755, File.join(directory, name))
    original = ENV.fetch('PATH')
    begin
      ENV['PATH'] = [directory, original].join(File::PATH_SEPARATOR)
      [directory, Erx::Fiasco.build_environment.fetch('PATH').split(File::PATH_SEPARATOR)]
    ensure
      ENV['PATH'] = original
    end
  end

  # A directory of the caller's PATH that holds no program of the build stays out of the
  # build's PATH, wherever it sits on the caller's PATH.
  def test_a_caller_directory_with_no_build_program_does_not_reach_the_build_path
    decoy, path = build_path_with_only('ninja')
    refute_includes path, decoy
    assert_equal Erx::BuildMemo::SYSTEM_DIRECTORIES, path.last(Erx::BuildMemo::SYSTEM_DIRECTORIES.size)
  end

  # And a directory holding a program the build names (perl, Fiasco's preprocessor, which
  # on FreeBSD lives beside the cross tools and on macOS in /usr/bin) reaches it, ahead of
  # the system's directories.
  def test_a_caller_directory_with_a_build_program_reaches_the_build_path
    %w[gmake gawk dtc perl].each do |name|
      home, path = build_path_with_only(name)
      assert_includes path, home, "#{name} found on the caller's PATH is named by its directory"
      assert_operator path.index(home), :<, path.index(Erx::BuildMemo::SYSTEM_DIRECTORIES.first)
    end
  end

  def test_banner_recipe_has_no_default_root_task
    root = File.expand_path('../..', __dir__)
    path = File.join(root, 'config/fiasco/modules.list')
    recipe = File.read(path)
    runner = Erx::Runner.new(owner_root: @directory, log_dir: File.join(@directory, 'logs'))
    result = runner.run(['perl', '-I', File.join(root, 'fiasco/mk/tool/lib'),
                         '-ML4::ModList', '-e',
                         'print join("\n", get_entries($ARGV[0], "")), "\n";', path],
                        name: 'module-list-fixture', deadline: 10)
    assert_equal "banner\n", File.binread(result.fetch('log'))
    refute_match(/\b(?:moe|ned|roottask)\b/, recipe)
  end
end
