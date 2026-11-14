# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'fileutils'
require 'minitest/autorun'
require 'open3'
require 'tmpdir'
require_relative '../fixtures/generated_tree'
require_relative '../../tools/lib/erx/fiasco_config'

# erx-gate: sanitizers

# The CPU feature words of the boot information page
# (liberx/backend/core/arch/aarch64/cpu_features.c, docs/design-arch-aarch64.md,
# "CPU feature words"), driven by test/fixtures/cpu_features_driver.c with
# identification words ISAR0 ISAR1 ISAR2 PFR0 PFR1.
class CpuFeaturesTest < Minitest::Test
  ROOT = File.expand_path('../..', __dir__)
  CORE = 'liberx/backend/core/arch/aarch64/cpu_features.c'
  DRIVER = 'test/fixtures/cpu_features_driver.c'

  CLAIMED = %w[FP ASIMD AES PMULL SHA1 SHA2 CRC32 ATOMICS FPHP ASIMDHP JSCVT FCMA LRCPC DCPOP SHA3 SM3 SM4
               ASIMDDP SHA512 ILRCPC FLAGM].freeze
  # Each option tools/lib/erx/fiasco_config.rb forbids, with the features whose state or
  # enable it would bring: a feature named here is refused however present the CPU says it is.
  FORBIDDEN_FEATURES = {
    'CONFIG_ARM_SVE' => %w[SVE SVE2 SVEAES SVEPMULL SVEBITPERM SVESHA3 SVESM4 SVEI8MM SVEF32MM SVEF64MM SVEBF16],
    'CONFIG_LAZY_FPU' => [],
    'CONFIG_CPU_VIRT' => []
  }.freeze
  # Never claimed on the stopgap, whatever its configuration: cpu_features.c's table has no row for them.
  NEVER = %w[PACA PACG BTI MTE CPUID].freeze

  # Every feature field at or past each threshold FreeBSD maps: unsigned fields 2,
  # FP and AdvSIMD 1 (half precision), SVE, DIT and BT 1, SSBS 2.
  ALL = %w[2222222222222220 2222222222222222 2222222222222222 0001000100110000 21].freeze

  def setup
    @directory = Dir.mktmpdir('erx-cpu-features-')
    sanitizers = ENV.fetch('ERX_SANITIZERS', '').split(',').reject(&:empty?)
    @flags = sanitizers.empty? ? [] : ["-fsanitize=#{sanitizers.join(',')}", '-fno-omit-frame-pointer', '-fno-sanitize-recover=all']
    @driver = build(File.join(ROOT, CORE), name: 'driver')
  end

  def teardown = FileUtils.remove_entry(@directory)

  def build(core, name:)
    output = File.join(@directory, name)
    log, status = Open3.capture2e(ENV.fetch('ERX_CLANG', 'clang'), '-std=c17', '-Wall', '-Wextra', '-Werror', '-pedantic', '-O1', '-g',
                                  *@flags, *Erx::Generated.include_flags(root: ROOT), '-I', File.join(ROOT, 'include'),
                                  '-I', ROOT, core, File.join(ROOT, DRIVER), '-o', output, stdin_data: '')
    assert status.success?, log
    output
  end

  # The names the driver prints for words, as [hwcap names, hwcap2 names].
  def features(words, driver: @driver)
    output, status = Open3.capture2e(driver, *words, stdin_data: '')
    assert status.success?, output
    match = /\Ahwcap(?<one>( \w+)*) hwcap2(?<two>( \w+)*)\n\z/.match(output)
    assert match, output
    [match[:one].split, match[:two].split]
  end

  def refused(words, driver: @driver)
    claimed = features(words, driver: driver).flatten
    claimed & (FORBIDDEN_FEATURES.values.flatten + NEVER)
  end

  def test_every_feature_present_gives_exactly_the_claimed_ones
    hwcap, hwcap2 = features(ALL)
    assert_equal CLAIMED.sort, hwcap.sort
    assert_empty hwcap2
  end

  def test_no_feature_fields_give_fp_and_simd_alone
    assert_equal [%w[FP ASIMD], []], features(%w[0 0 0 0 0])
  end

  def test_fp_and_simd_absent_give_nothing
    assert_equal [[], []], features(%w[0 0 0 ff0000 0])
    assert_equal [%w[ASIMD], []], features(%w[0 0 0 f0000 0])
  end

  # Each claimed field at the value below its next threshold claims only what that value has.
  def test_each_claimed_field_at_its_thresholds
    {
      %w[10 0 0 0 0] => %w[AES], %w[20 0 0 0 0] => %w[AES PMULL], %w[100 0 0 0 0] => %w[SHA1],
      %w[1000 0 0 0 0] => %w[SHA2], %w[2000 0 0 0 0] => %w[SHA2 SHA512], %w[10000 0 0 0 0] => %w[CRC32],
      %w[100000 0 0 0 0] => [], %w[200000 0 0 0 0] => %w[ATOMICS], %w[100000000 0 0 0 0] => %w[SHA3],
      %w[1000000000 0 0 0 0] => %w[SM3], %w[10000000000 0 0 0 0] => %w[SM4], %w[100000000000 0 0 0 0] => %w[ASIMDDP],
      %w[10000000000000 0 0 0 0] => %w[FLAGM], %w[0 1 0 0 0] => %w[DCPOP], %w[0 1000 0 0 0] => %w[JSCVT],
      %w[0 10000 0 0 0] => %w[FCMA], %w[0 100000 0 0 0] => %w[LRCPC], %w[0 200000 0 0 0] => %w[LRCPC ILRCPC],
      %w[0 0 0 110000 0] => %w[FP FPHP ASIMD ASIMDHP]
    }.each do |words, expected|
      assert_equal (%w[FP ASIMD] | expected).sort, features(words).first.sort, words.inspect
    end
  end

  # The driver's whole output for fixed snapshots: none and every field all ones, then six
  # drawn from Random.new(91), which mix signed FP and AdvSIMD values with set unsigned fields.
  SNAPSHOTS = {
    %w[0 0 0 0 0] => 'FP ASIMD',
    %w[ffffffffffffffff ffffffffffffffff ffffffffffffffff ffffffffffffffff ffffffffffffffff] =>
      'AES PMULL SHA1 SHA2 CRC32 ATOMICS JSCVT FCMA LRCPC DCPOP SHA3 SM3 SM4 ASIMDDP SHA512 ILRCPC FLAGM',
    %w[3374f8b2fda406ae 543aaf6a7a6380d2 4be7675d91f65874 17e4b71dedecc1ee 5544a72475583365] =>
      'AES PMULL SHA1 CRC32 ATOMICS JSCVT FCMA LRCPC DCPOP SHA3 SM3 SM4 ASIMDDP ILRCPC FLAGM',
    %w[b9a8328289f3609c a7013eaa5220d1f5 813ddb0ebff6781c f2844391495b4491 a09d63d8650425fa] =>
      'ASIMD AES PMULL SHA2 CRC32 ATOMICS ASIMDHP JSCVT LRCPC DCPOP SHA3 SM3 SM4 ASIMDDP SHA512 ILRCPC FLAGM',
    %w[fe067a413254de12 137cae9475c96728 57b5315619cf85dd 4e9353715667b66a b5cff894763ada6e] =>
      'FP ASIMD AES SHA1 SHA2 CRC32 ATOMICS FPHP ASIMDHP JSCVT FCMA LRCPC DCPOP SHA3 SM3 SM4 ASIMDDP SHA512 ILRCPC',
    %w[ead5529186d369fd 14b64d2b84c5c0c6 1015d6b3a807428e 9508fb449aeb053d ab50932209fd14f9] =>
      'AES PMULL SHA1 SHA2 CRC32 ATOMICS JSCVT FCMA LRCPC DCPOP SHA3 SM3 SM4 ASIMDDP SHA512 ILRCPC FLAGM',
    %w[26432772647884e 6c03618e2318474f 65385f71a64c6808 12bd8053c3733d4a c532446ed1027435] =>
      'FP ASIMD AES PMULL SHA1 SHA2 CRC32 ATOMICS FPHP ASIMDHP JSCVT FCMA LRCPC DCPOP SHA3 SM3 SM4 ASIMDDP SHA512 FLAGM',
    %w[3079d90cbd8fd4ef 77cf5b229108c542 a6d8fdc3b5a0333a 216caab11bacad4 1166cf76568613a3] =>
      'AES PMULL SHA1 SHA2 CRC32 ATOMICS JSCVT FCMA DCPOP SHA3 SM4 ASIMDDP SHA512 FLAGM'
  }.freeze

  def test_snapshots_give_their_pinned_words
    SNAPSHOTS.each do |words, hwcap|
      output, status = Open3.capture2e(@driver, *words, stdin_data: '')
      assert status.success?, output
      assert_equal "hwcap #{hwcap} hwcap2\n", output, words.inspect
    end
  end

  def test_forbidden_features_are_refused_when_the_cpu_has_them
    assert_empty refused(ALL)
    assert_empty refused(%w[ffffffffffffffff ffffffffffffffff ffffffffffffffff 7777777777777777 ffffffffffffffff])
  end

  # The table above names every option the stopgap's configuration forbids, so a new one
  # fails here until the features it touches are listed and refused.
  def test_the_forbidden_table_follows_the_fiasco_configuration
    assert_equal Erx::FiascoConfig::FORBIDDEN.sort, FORBIDDEN_FEATURES.keys.sort
  end

  # CPUID would have a program read MIDR_EL1 from user mode (OpenSSL's armcap.c does), which
  # the stopgap does not emulate: no field gives it, and it is never claimed.
  def test_cpuid_is_never_claimed
    [ALL, %w[0 0 0 0 0], %w[ffffffffffffffff ffffffffffffffff ffffffffffffffff 7777777777777777 ffffffffffffffff]].each do |words|
      refute_includes features(words).first, 'CPUID', words.inspect
    end
  end

  # Seeded fault: a row that claims CPUID must be caught.
  def test_a_row_that_claims_cpuid_is_caught
    driver = seeded(name: 'cpuid', row: '{ 0, 0, { .hwcap = HWCAP_CPUID } },')
    assert_raises(Minitest::Assertion) { refute_includes features(ALL, driver: driver).first, 'CPUID' }
    assert_equal %w[CPUID], refused(%w[0 0 0 0 0], driver: driver)
  end

  # Seeded fault: a row that claims SVE must be caught.
  def test_a_row_that_claims_sve_is_caught
    row = '{ erx_sysreg_id_aa64pfr0_el1_sve_get(pfr0), 1, { .hwcap = HWCAP_SVE } },'
    assert_equal %w[SVE], refused(ALL, driver: seeded(name: 'sve', row: row))
  end

  # Seeded fault: a row that claims an AT_HWCAP2 bit, BTI, must be caught, so the table's
  # second word is checked too.
  def test_a_row_that_claims_bti_is_caught
    row = '{ erx_sysreg_id_aa64pfr1_el1_bt_get(id[ERX_CPU_ID_WORD_AA64PFR1]), 1, { .hwcap2 = HWCAP2_BTI } },'
    assert_equal %w[BTI], refused(ALL, driver: seeded(name: 'bti', row: row))
  end

  private

  # A driver over the core with row added to its table, before the FP row.
  def seeded(name:, row:)
    source = File.read(File.join(ROOT, CORE))
    anchor = "\t\t{ signed_field(erx_sysreg_id_aa64pfr0_el1_fp_get(pfr0)), 0, { .hwcap = HWCAP_FP } },\n"
    assert_includes source, anchor
    path = File.join(@directory, "seeded-#{name}.c")
    File.write(path, source.sub(anchor) { "\t\t#{row}\n#{anchor}" })
    build(path, name: File.basename(path, '.c'))
  end
end
