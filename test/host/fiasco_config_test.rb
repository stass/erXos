# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'minitest/autorun'
require 'rbconfig'
require 'tmpdir'
require_relative '../../tools/lib/erx/build_kind'
require_relative '../../tools/lib/erx/fiasco_config'
require_relative '../../tools/lib/erx/runner'

class FiascoConfigTest < Minitest::Test
  ROOT = File.expand_path('../..', __dir__)
  DEVELOPMENT = Erx::BuildKind::DEVELOPMENT
  RELEASE = Erx::BuildKind::RELEASE

  # A resolved configuration as Kconfig writes it: a header comment, every
  # required option set and every forbidden one written as not set.
  RESOLVED = <<~CONFIG
    #
    # Automatically generated file; DO NOT EDIT.
    # Fiasco configuration
    #
    CONFIG_HAS_FPU_OPTION=y
    CONFIG_ARM=y

    #
    # Target configuration
    #
    # CONFIG_CPU_VIRT is not set
    CONFIG_FPU=y
    # CONFIG_ARM_SVE is not set
    CONFIG_SYNC_CLOCK=y
    CONFIG_BENCHMARKING=y
    CONFIG_PERF_CNT=y
    CONFIG_PERF_CNT_USER=y
    CONFIG_MP_MAX_CPUS=8
    CONFIG_ABI_VF=y
    CONFIG_LABEL="erx"
  CONFIG

  # RESOLVED with the line that names the option replaced by another.
  def replacing(name, with:)
    RESOLVED.lines.map { |text| text.match?(/\b#{name}\b/) ? "#{with}\n" : text }.join
  end

  def without(name, from: RESOLVED)
    from.lines.reject { |text| text.match?(/\b#{name}\b/) }.join
  end

  # The check of a development kernel's configuration, unless kind says otherwise.
  def violations(text, kind: DEVELOPMENT) = Erx::FiascoConfig.violations(text, kind: kind)

  def test_the_forks_resolved_configuration_passes
    assert_empty violations(RESOLVED)
  end

  def test_forbidden_options_may_be_absent
    stripped = Erx::FiascoConfig::FORBIDDEN.reduce(RESOLVED) { |text, name| without(name, from: text) }
    assert_empty violations(stripped)
  end

  # The case a `select` produces: BENCHMARKING selecting LAZY_FPU writes it
  # set even when the defconfig says it is not.
  def test_lazy_fpu_set_fails
    resolved = RESOLVED.sub("CONFIG_FPU=y\n", "CONFIG_FPU=y\nCONFIG_LAZY_FPU=y\n")
    assert_equal ['CONFIG_LAZY_FPU must be unset, found "y"'], violations(resolved)
  end

  def test_each_forbidden_option_set_fails
    %w[CONFIG_ARM_SVE CONFIG_CPU_VIRT].each do |name|
      violations = violations(replacing(name, with: "#{name}=y"))
      assert_equal ["#{name} must be unset, found \"y\""], violations
    end
  end

  def test_a_forbidden_option_with_any_value_fails
    assert_equal ['CONFIG_CPU_VIRT must be unset, found "n"'],
                 violations(replacing('CONFIG_CPU_VIRT', with: 'CONFIG_CPU_VIRT=n'))
  end

  def test_each_required_option_unset_or_absent_fails
    Erx::FiascoConfig::REQUIRED.each do |name|
      assert_equal ["#{name} must be y, found unset"],
                   violations(replacing(name, with: "# #{name} is not set"))
      assert_equal ["#{name} must be y, found unset"], violations(without(name))
    end
  end

  def test_a_required_option_with_another_value_fails
    assert_equal ['CONFIG_SYNC_CLOCK must be y, found "m"'],
                 violations(replacing('CONFIG_SYNC_CLOCK', with: 'CONFIG_SYNC_CLOCK=m'))
  end

  # A suffix of a required name is a different option.
  def test_a_longer_name_does_not_stand_in_for_a_required_option
    resolved = without('CONFIG_FPU') + "CONFIG_FPU_EXTRA=y\n"
    assert_equal ['CONFIG_FPU must be y, found unset'], violations(resolved)
  end

  def test_every_violation_is_reported
    resolved = replacing('CONFIG_ARM_SVE', with: 'CONFIG_ARM_SVE=y').sub("CONFIG_BENCHMARKING=y\n", '')
    assert_equal ['CONFIG_BENCHMARKING must be y, found unset', 'CONFIG_ARM_SVE must be unset, found "y"'],
                 violations(resolved)
  end

  # Seeded faults: the debugger or the console input on keeps a panic on the
  # console with interrupts off instead of resetting, so no build takes either;
  # JDB selects INPUT.
  def test_the_debugger_and_console_input_fail_every_build
    [DEVELOPMENT, RELEASE].each do |kind|
      assert_equal [%q(CONFIG_JDB must be unset, found "y"), %q(CONFIG_INPUT must be unset, found "y")],
                   violations("#{RESOLVED}CONFIG_INPUT=y\nCONFIG_JDB=y\n", kind: kind)
      assert_empty violations("#{RESOLVED}# CONFIG_INPUT is not set\n# CONFIG_JDB is not set\n", kind: kind)
    end
  end

  def test_an_unknown_build_kind_is_refused
    assert_raises(Erx::Error) { violations(RESOLVED, kind: 'production') }
  end

  def test_the_release_defconfig_is_the_development_one_with_its_newline
    development = "# A comment\nCONFIG_ARM=y\n# CONFIG_COV is not set\n"
    assert_equal development, Erx::FiascoConfig.release_defconfig(development)
    assert_equal "CONFIG_ARM=y\n", Erx::FiascoConfig.release_defconfig('CONFIG_ARM=y')
  end

  def test_the_checked_in_defconfig_derives_a_release_defconfig
    development = File.binread(File.join(ROOT, 'config/fiasco/kernel.defconfig'))
    release = Erx::FiascoConfig.release_defconfig(development)
    assert release.start_with?(development)
    assert_empty violations(release, kind: RELEASE)
  end

  def test_an_option_named_twice_is_refused
    error = assert_raises(Erx::Error) do
      violations(RESOLVED + "# CONFIG_LAZY_FPU is not set\nCONFIG_LAZY_FPU=y\n")
    end
    assert_includes error.message, 'CONFIG_LAZY_FPU twice'
  end

  def test_a_line_kconfig_does_not_write_is_refused
    ['CONFIG_LAZY_FPU = y', ' CONFIG_LAZY_FPU=y', 'LAZY_FPU=y', '#CONFIG_LAZY_FPU=y',
     "CONFIG_FPU=y\r"].each do |line|
      error = assert_raises(Erx::Error) { violations(RESOLVED + "#{line}\n") }
      assert_match(/line \d+ is not a Kconfig line/, error.message)
    end
  end

  def test_non_ascii_and_oversized_input_is_refused
    assert_raises(Erx::Error) { violations(RESOLVED + "# \xC3\xA9\n") }
    assert_raises(Erx::Error) { violations("#\n" * (Erx::FiascoConfig::MAX_LINES + 1)) }
    assert_raises(Erx::Error) { violations('#' * (Erx::FiascoConfig::MAX_BYTES + 1)) }
  end

  def test_check_names_the_file_and_every_violation
    Dir.mktmpdir('erx-fiasco-config-') do |directory|
      path = File.join(directory, 'globalconfig.out')
      File.write(path, RESOLVED)
      assert_nil Erx::FiascoConfig.check(path, kind: DEVELOPMENT)
      File.write(path, RESOLVED.sub("CONFIG_FPU=y\n", "CONFIG_FPU=y\nCONFIG_LAZY_FPU=y\n"))
      error = assert_raises(Erx::FiascoConfig::Violation) { Erx::FiascoConfig.check(path, kind: DEVELOPMENT) }
      assert_includes error.message, path
      assert_includes error.message, 'CONFIG_LAZY_FPU must be unset'
    end
  end

  def test_command_line_check_exits_nonzero_on_a_violation
    Dir.mktmpdir('erx-fiasco-config-') do |directory|
      runner = Erx::Runner.new(owner_root: directory, log_dir: File.join(directory, 'logs'))
      path = File.join(directory, 'globalconfig.out')
      check = [RbConfig.ruby, File.join(ROOT, 'tools/check_fiasco_config.rb'), path]
      File.write(path, RESOLVED)
      runner.run(check, name: 'check-fiasco-config-passing', deadline: 30)
      File.write(path, replacing('CONFIG_ARM_SVE', with: 'CONFIG_ARM_SVE=y'))
      error = assert_raises(Erx::CommandError) do
        runner.run(check, name: 'check-fiasco-config-failing', deadline: 30)
      end
      assert_includes File.binread(error.result.fetch('log')), 'CONFIG_ARM_SVE must be unset'
    end
  end
end
