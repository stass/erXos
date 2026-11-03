# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'minitest/autorun'
require 'rbconfig'
require 'tmpdir'
require_relative '../../tools/lib/erx/fiasco_config'
require_relative '../../tools/lib/erx/runner'

class FiascoConfigTest < Minitest::Test
  ROOT = File.expand_path('../..', __dir__)

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
    CONFIG_PERFORMANCE=y
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

  def test_the_forks_resolved_configuration_passes
    assert_empty Erx::FiascoConfig.violations(RESOLVED)
  end

  def test_forbidden_options_may_be_absent
    stripped = Erx::FiascoConfig::FORBIDDEN.reduce(RESOLVED) { |text, name| without(name, from: text) }
    assert_empty Erx::FiascoConfig.violations(stripped)
  end

  # The case a `select` produces: PERFORMANCE selecting LAZY_FPU writes it
  # set even when the defconfig says it is not.
  def test_lazy_fpu_set_fails
    resolved = RESOLVED.sub("CONFIG_FPU=y\n", "CONFIG_FPU=y\nCONFIG_LAZY_FPU=y\n")
    assert_equal ['CONFIG_LAZY_FPU must be unset, found "y"'], Erx::FiascoConfig.violations(resolved)
  end

  def test_each_forbidden_option_set_fails
    %w[CONFIG_ARM_SVE CONFIG_CPU_VIRT].each do |name|
      violations = Erx::FiascoConfig.violations(replacing(name, with: "#{name}=y"))
      assert_equal ["#{name} must be unset, found \"y\""], violations
    end
  end

  def test_a_forbidden_option_with_any_value_fails
    assert_equal ['CONFIG_CPU_VIRT must be unset, found "n"'],
                 Erx::FiascoConfig.violations(replacing('CONFIG_CPU_VIRT', with: 'CONFIG_CPU_VIRT=n'))
  end

  def test_each_required_option_unset_or_absent_fails
    Erx::FiascoConfig::REQUIRED.each do |name|
      assert_equal ["#{name} must be y, found unset"],
                   Erx::FiascoConfig.violations(replacing(name, with: "# #{name} is not set"))
      assert_equal ["#{name} must be y, found unset"], Erx::FiascoConfig.violations(without(name))
    end
  end

  def test_a_required_option_with_another_value_fails
    assert_equal ['CONFIG_SYNC_CLOCK must be y, found "m"'],
                 Erx::FiascoConfig.violations(replacing('CONFIG_SYNC_CLOCK', with: 'CONFIG_SYNC_CLOCK=m'))
  end

  # A suffix of a required name is a different option.
  def test_a_longer_name_does_not_stand_in_for_a_required_option
    resolved = without('CONFIG_FPU') + "CONFIG_FPU_EXTRA=y\n"
    assert_equal ['CONFIG_FPU must be y, found unset'], Erx::FiascoConfig.violations(resolved)
  end

  def test_every_violation_is_reported
    resolved = replacing('CONFIG_ARM_SVE', with: 'CONFIG_ARM_SVE=y').sub("CONFIG_PERFORMANCE=y\n", '')
    assert_equal ['CONFIG_PERFORMANCE must be y, found unset', 'CONFIG_ARM_SVE must be unset, found "y"'],
                 Erx::FiascoConfig.violations(resolved)
  end

  def test_an_option_named_twice_is_refused
    error = assert_raises(Erx::Error) do
      Erx::FiascoConfig.violations(RESOLVED + "# CONFIG_LAZY_FPU is not set\nCONFIG_LAZY_FPU=y\n")
    end
    assert_includes error.message, 'CONFIG_LAZY_FPU twice'
  end

  def test_a_line_kconfig_does_not_write_is_refused
    ['CONFIG_LAZY_FPU = y', ' CONFIG_LAZY_FPU=y', 'LAZY_FPU=y', '#CONFIG_LAZY_FPU=y',
     "CONFIG_FPU=y\r"].each do |line|
      error = assert_raises(Erx::Error) { Erx::FiascoConfig.violations(RESOLVED + "#{line}\n") }
      assert_match(/line \d+ is not a Kconfig line/, error.message)
    end
  end

  def test_non_ascii_and_oversized_input_is_refused
    assert_raises(Erx::Error) { Erx::FiascoConfig.violations(RESOLVED + "# \xC3\xA9\n") }
    assert_raises(Erx::Error) { Erx::FiascoConfig.violations("#\n" * (Erx::FiascoConfig::MAX_LINES + 1)) }
    assert_raises(Erx::Error) { Erx::FiascoConfig.violations('#' * (Erx::FiascoConfig::MAX_BYTES + 1)) }
  end

  def test_check_names_the_file_and_every_violation
    Dir.mktmpdir('erx-fiasco-config-') do |directory|
      path = File.join(directory, 'globalconfig.out')
      File.write(path, RESOLVED)
      assert_nil Erx::FiascoConfig.check(path)
      File.write(path, RESOLVED.sub("CONFIG_FPU=y\n", "CONFIG_FPU=y\nCONFIG_LAZY_FPU=y\n"))
      error = assert_raises(Erx::FiascoConfig::Violation) { Erx::FiascoConfig.check(path) }
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
