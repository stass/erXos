# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'fileutils'
require 'minitest/autorun'
require 'tmpdir'
require_relative '../../tools/lib/erx/fiasco'

# Resolves the fork's real Kconfig with the real defconfig, as the
# fiasco-kernel-config step does, and runs the configuration check over the
# result. The seeded case puts Fiasco's LAZY_FPU option back with the
# `select` from BENCHMARKING and gives the defconfig a line saying it is not
# set: the select wins over that line, and the check must catch the result.
# The fork's Kconfig has no debugger option, so the resolved configuration
# names none of the debugger's lines that the defconfig keeps for L4Re's kernel;
# the defconfig resolves with console input unset, which no
# select turns back on (INPUT defaults to on where the serial option exists),
# and both build kinds' checks accept it.
class FiascoConfigIntegrationTest < Minitest::Test
  ROOT = File.expand_path('../..', __dir__)
  DEFCONFIG = File.join(ROOT, 'config/fiasco/kernel.defconfig')
  DEVELOPMENT = Erx::BuildKind::DEVELOPMENT
  RELEASE = Erx::BuildKind::RELEASE

  # Fiasco's own text of the option, its architecture flag and the select.
  LAZY_OPTIONS = <<~KCONFIG
    config HAS_LAZY_FPU
    	bool

    config LAZY_FPU
    	bool "Enable lazy FPU switching" if HAS_LAZY_FPU && FPU
    	depends on FPU && HAS_LAZY_FPU
    	default y if !AMD64

  KCONFIG
  LAZY_SELECT = "\tselect LAZY_FPU if FPU && HAS_LAZY_FPU\n"
  LAZY_ARCHSELECT = "# ARCHSELECT:     HAS_LAZY_FPU\n"

  def setup
    parent = File.join(ROOT, 'build/test')
    FileUtils.mkdir_p(parent)
    @directory = Dir.mktmpdir('fiasco-config-', parent)
    @runner = Erx::Runner.new(owner_root: @directory, log_dir: File.join(@directory, 'logs'))
  end

  def teardown
    FileUtils.remove_entry(@directory) if passed?
  end

  def test_the_forks_kconfig_resolves_to_a_configuration_the_check_accepts
    resolved = resolve(kernel_copy('fork'), name: 'fork')
    assert_empty Erx::FiascoConfig.violations(File.binread(resolved), kind: DEVELOPMENT)
    assert_nil Erx::FiascoConfig.check(resolved, kind: DEVELOPMENT)
    lines = File.binread(resolved).lines
    refute(lines.any? { |line| line.include?("CONFIG_JDB") }, "the fork's Kconfig has no debugger option")
    assert_includes lines, "# CONFIG_INPUT is not set\n"
    assert_nil Erx::FiascoConfig.check(resolved, kind: RELEASE)
  end

  def test_lazy_fpu_seeded_back_with_its_select_fails_the_check
    source = kernel_copy('seeded')
    seed(File.join(source, 'src/Kconfig'), after: "config HAS_FPU_OPTION\n\tbool\n\n", text: LAZY_OPTIONS)
    seed(File.join(source, 'src/Kconfig'), after: "\tselect NO_FRAME_PTR\n", text: LAZY_SELECT)
    seed(File.join(source, 'src/kern/arm/Kconfig'), after: "# ARCHSELECT:     HAS_FPU_OPTION\n",
                                                     text: LAZY_ARCHSELECT)
    resolved = resolve(source, name: 'seeded', defconfig: File.binread(DEFCONFIG) + "# CONFIG_LAZY_FPU is not set\n")
    assert_includes File.binread(resolved).lines, "CONFIG_LAZY_FPU=y\n"
    error = assert_raises(Erx::FiascoConfig::Violation) { Erx::FiascoConfig.check(resolved, kind: DEVELOPMENT) }
    assert_includes error.message, 'CONFIG_LAZY_FPU must be unset'
  end

  private

  def kernel_copy(name)
    destination = File.join(@directory, name, 'kernel')
    FileUtils.mkdir_p(File.dirname(destination))
    FileUtils.cp_r(File.join(ROOT, 'fiasco/kernel'), destination)
    destination
  end

  # Inserts text after the one passage of path that after names.
  def seed(path, after:, text:)
    content = File.binread(path)
    assert_equal 1, content.scan(after).size, "seed anchor in #{path}"
    File.binwrite(path, content.sub(after) { after + text })
  end

  def resolve(source, name:, defconfig: File.binread(DEFCONFIG))
    build = File.join(@directory, name, 'build')
    path = File.join(@directory, name, 'kernel.defconfig')
    File.binwrite(path, defconfig)
    @runner.run(['gmake', '-C', source, "B=#{build}", "DEFCONFIG=#{path}",
                 "CROSS_COMPILE=#{Erx::FiascoToolchain::CROSS_COMPILE}", *Erx::Fiasco.host_variables],
                name: "fiasco-config-#{name}", deadline: 120, env: Erx::Fiasco.build_environment)
    File.join(build, 'globalconfig.out')
  end
end
