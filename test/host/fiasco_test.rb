# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'minitest/autorun'
require 'tmpdir'
require 'rubygems/package'
require 'stringio'
require 'zlib'
require_relative '../../tools/lib/erx/fiasco'

class FiascoTest < Minitest::Test
  # The recording runner resolves a configuration by copying it, so the
  # fixture is already in the shape the configuration check accepts.
  KERNEL_CONFIG = "CONFIG_ARM=y\n# CONFIG_CPU_VIRT is not set\nCONFIG_FPU=y\nCONFIG_SYNC_CLOCK=y\n" \
                  "CONFIG_PERFORMANCE=y\nCONFIG_PERF_CNT_USER=y\n"

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
    @fiasco = FixtureBuild.new(root: @directory, runner: @runner, compiler: '/fixture/clang')
    %w[kernel mk l4re-core bootstrap libfdt drivers-frst].each do |name|
      FileUtils.mkdir_p(File.join(@directory, 'fiasco', name))
    end
    [*%w[kernel include liberx], *Erx::FiascoInputs::GENERATED_ROOTS].each do |name|
      FileUtils.mkdir_p(File.join(@directory, name))
    end
    File.write(File.join(@directory, 'fiasco/mk/Makefile'), '# inherited')
    FileUtils.mkdir_p(File.join(@directory, 'config/fiasco'))
    File.write(kernel_config, KERNEL_CONFIG)
    File.write(user_config, "CONFIG_BUILD_ARCH_arm64=y\n")
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
    assert_includes users.fetch(:argv), 'CROSS_COMPILE=aarch64-elf-'
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
