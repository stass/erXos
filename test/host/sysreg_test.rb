# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'minitest/autorun'
require 'rbconfig'
require 'tmpdir'
require 'fileutils'
require_relative '../../tools/lib/erx/sysreg'
require_relative '../../tools/lib/erx/runner'
require_relative '../fixtures/sysreg_fixture'

class SysregTest < Minitest::Test
  REPOSITORY = File.expand_path('../..', __dir__)

  # A tree holding a policy-only specification and a synthetic Registers.json,
  # so refresh and verify run without Arm's archive.
  def with_synthetic_tree
    Dir.mktmpdir('erx-sysreg-refresh-') do |root|
      FileUtils.mkdir_p(File.join(root, 'hw/sysreg'))
      FileUtils.mkdir_p(File.join(root, 'build/third_party/arm-registers'))
      bytes = JSON.generate([SysregFixture.record])
      File.binwrite(File.join(root, Erx::Sysreg::SOURCE), bytes)
      File.binwrite(File.join(root, Erx::Sysreg::SPECIFICATION), JSON.generate(SysregFixture.specification(bytes)))
      yield root
    end
  end

  def test_refresh_fills_the_facts_and_verify_catches_an_edit
    with_synthetic_tree do |root|
      assert_raises(Erx::Error) { Erx::Sysreg.verify(root: root) }
      assert Erx::Sysreg.refresh(root: root)
      assert Erx::Sysreg.verify(root: root)
      refute Erx::Sysreg.refresh(root: root)
      register = JSON.parse(File.binread(File.join(root, Erx::Sysreg::SPECIFICATION))).fetch('registers').first
      assert_equal Erx::Sysreg::POLICY_KEYS + Erx::Sysreg::FACT_KEYS, register.keys
      File.open(File.join(root, Erx::Sysreg::SPECIFICATION), 'ab') { |file| file.write(' ') }
      assert_raises(Erx::Error) { Erx::Sysreg.verify(root: root) }
      assert Erx::Sysreg.refresh(root: root)
      assert Erx::Sysreg.verify(root: root)
      assert_equal %w[aarch64.json], Dir.children(File.join(root, 'hw/sysreg'))
    end
  end

  def test_refresh_without_the_archive_names_the_fetch
    with_synthetic_tree do |root|
      File.unlink(File.join(root, Erx::Sysreg::SOURCE))
      before = File.binread(File.join(root, Erx::Sysreg::SPECIFICATION))
      error = assert_raises(Erx::Error) { Erx::Sysreg.refresh(root: root) }
      assert_includes error.message, 'tools/erx fetch --source arm-registers'
      assert_equal before, File.binread(File.join(root, Erx::Sysreg::SPECIFICATION))
    end
  end

  def test_symlinked_specification_is_refused
    with_synthetic_tree do |root|
      target = File.join(root, 'elsewhere.json')
      File.rename(File.join(root, Erx::Sysreg::SPECIFICATION), target)
      File.symlink(target, File.join(root, Erx::Sysreg::SPECIFICATION))
      before = File.binread(target)
      error = assert_raises(Erx::Error) { Erx::Sysreg.refresh(root: root) }
      assert_includes error.message, 'not a symlink'
      assert_equal before, File.binread(target)
    end
  end

  def test_symlinked_directory_is_refused_and_its_target_untouched
    with_synthetic_tree do |root|
      File.rename(File.join(root, 'hw/sysreg'), File.join(root, 'elsewhere'))
      File.symlink(File.join(root, 'elsewhere'), File.join(root, 'hw/sysreg'))
      before = File.binread(File.join(root, 'elsewhere/aarch64.json'))
      assert_raises(Erx::Error) { Erx::Sysreg.refresh(root: root) }
      assert_equal before, File.binread(File.join(root, 'elsewhere/aarch64.json'))
      assert_equal %w[aarch64.json], Dir.children(File.join(root, 'elsewhere'))
    end
  end

  def test_missing_specification_says_so
    with_synthetic_tree do |root|
      File.unlink(File.join(root, Erx::Sysreg::SPECIFICATION))
      error = assert_raises(Erx::Error) { Erx::Sysreg.verify(root: root) }
      assert_includes error.message, 'is missing'
    end
  end

  def test_cli_verifies_and_refreshes_a_given_tree
    with_synthetic_tree do |root|
      runner = Erx::Runner.new(owner_root: root, log_dir: File.join(root, 'logs'))
      command = [RbConfig.ruby, File.join(REPOSITORY, 'tools/erx'), 'sysreg', 'refresh', '--root', root]
      stale = assert_raises(Erx::CommandError) { runner.run(command + ['--verify'], name: 'stale-sysreg', deadline: 60) }
      assert_equal 1, stale.result.fetch('exit_status')
      runner.run(command, name: 'refresh-sysreg', deadline: 60)
      runner.run(command + ['--verify'], name: 'verify-sysreg', deadline: 60)
    end
  end

  def test_nonregular_source_is_rejected_without_waiting_for_a_writer
    with_synthetic_tree do |root|
      File.unlink(File.join(root, Erx::Sysreg::SOURCE))
      runner = Erx::Runner.new(owner_root: root, log_dir: File.join(root, 'logs'))
      runner.run(['mkfifo', File.join(root, Erx::Sysreg::SOURCE)], name: 'fifo-source', deadline: 5)
      error = assert_raises(Erx::CommandError) do
        runner.run([RbConfig.ruby, File.join(REPOSITORY, 'tools/erx'), 'sysreg', 'refresh', '--root', root],
                   name: 'nonregular-sysreg', deadline: 30)
      end
      assert_equal 'failed', error.result.fetch('state')
      assert_equal 1, error.result.fetch('exit_status')
    end
  end

  def extract(records)
    bytes = JSON.generate(records)
    declaration = Erx::Sysreg.selection(JSON.generate(SysregFixture.specification(bytes)))
    Erx::Sysreg.extract(bytes, declaration: declaration)
  end

  def test_complete_fixed_layout_and_encoding
    result = extract([SysregFixture.record])
    register = result.fetch('registers').first
    assert_equal 'COUNTER_EL0', register.fetch('name')
    assert_equal({ 'op0' => 3, 'op1' => 3, 'CRn' => 14, 'CRm' => 0, 'op2' => 2 }, register.fetch('encoding'))
    assert_equal [{ 'name' => 'Count', 'offset' => 0, 'width' => 64 }], register.fetch('fields')
    assert_equal 'isb', register.fetch('read_barrier')
  end

  def test_missing_duplicate_conditional_and_overlapping_records_are_rejected
    assert_raises(Erx::Error) { extract([{}]) }
    assert_raises(Erx::Error) { extract([SysregFixture.record, SysregFixture.record]) }
    record = SysregFixture.record
    record.fetch('fieldsets').first['condition']['value'] = false
    assert_raises(Erx::Error) { extract([record]) }
    record = SysregFixture.record
    record.fetch('fieldsets').first.fetch('values') << record.fetch('fieldsets').first.fetch('values').first.dup
    assert_raises(Erx::Error) { extract([record]) }
  end

  def test_malformed_record_shapes_and_bit_strings_are_typed
    [nil, [], 42].each do |value|
      record = SysregFixture.record
      record['_meta'] = value
      assert_raises(Erx::Error) { extract([record]) }
      record = SysregFixture.record
      record['accessors'] = value
      assert_raises(Erx::Error) { extract([record]) }
    end
    record = SysregFixture.record
    record.fetch('accessors').first.fetch('encoding').first.fetch('encodings').fetch('op0')['value'] = "'111'"
    assert_raises(Erx::Error) { extract([record]) }
  end

  def test_source_pin_and_access_policy_are_enforced
    bytes = JSON.generate([SysregFixture.record])
    declaration = Erx::Sysreg.selection(JSON.generate(SysregFixture.specification(bytes)))
    assert_raises(Erx::Error) { Erx::Sysreg.extract(bytes + ' ', declaration: declaration) }
    bad_policy = SysregFixture.specification(bytes)
    bad_policy.fetch('registers').first['write'] = true
    assert_raises(Erx::Error) { Erx::Sysreg.selection(JSON.generate(bad_policy)) }
  end

  def test_selection_takes_policy_alone_or_policy_with_every_fact
    bytes = JSON.generate([SysregFixture.record])
    full = JSON.parse(JSON.generate(extract([SysregFixture.record])))
    assert_equal SysregFixture.specification(bytes).fetch('registers'),
                 Erx::Sysreg.selection(JSON.generate(full)).fetch('registers')
    partial = JSON.parse(JSON.generate(full))
    partial.fetch('registers').first.delete('fields')
    assert_raises(Erx::Error) { Erx::Sysreg.selection(JSON.generate(partial)) }
    extra = JSON.parse(JSON.generate(full))
    extra.fetch('registers').first['note'] = 'x'
    assert_raises(Erx::Error) { Erx::Sysreg.selection(JSON.generate(extra)) }
  end

  # The checked-in specification is an input every build reads without Arm's
  # archive: its one reader checks every fact, and these are the counter facts
  # the kernel relies on. The comparison with the archive itself is
  # test/integration/sysreg_refresh_test.rb, which `make check` excuses.
  def test_checked_in_specification_parses_with_counter_facts
    bytes = File.binread(File.join(REPOSITORY, Erx::Sysreg::SPECIFICATION))
    specification = Erx::Sysreg.specification(bytes)
    assert_equal %w[CNTFRQ_EL0 CNTPCT_EL0 CNTVCT_EL0 ID_AA64ISAR0_EL1 ID_AA64ISAR1_EL1 ID_AA64ISAR2_EL1 ID_AA64PFR0_EL1 ID_AA64PFR1_EL1],
                 specification.fetch('registers').map { |register| register.fetch('name') }
    rows = specification.fetch('registers').to_h { |register| [register.fetch('name'), register] }
    assert_equal({ 'op0' => 3, 'op1' => 3, 'CRn' => 14, 'CRm' => 0, 'op2' => 1 }, rows.fetch('CNTPCT_EL0').fetch('encoding'))
    assert_equal [{ 'name' => 'PhysicalCount', 'offset' => 0, 'width' => 64 }], rows.fetch('CNTPCT_EL0').fetch('fields')
    assert_equal({ 'op0' => 3, 'op1' => 3, 'CRn' => 14, 'CRm' => 0, 'op2' => 2 }, rows.fetch('CNTVCT_EL0').fetch('encoding'))
    assert_equal [{ 'name' => 'VirtualCount', 'offset' => 0, 'width' => 64 }], rows.fetch('CNTVCT_EL0').fetch('fields')
    assert_equal({ 'name' => 'ClockFreq', 'offset' => 0, 'width' => 32 }, rows.fetch('CNTFRQ_EL0').fetch('fields').first)
    assert_equal({ 'op0' => 3, 'op1' => 0, 'CRn' => 0, 'CRm' => 6, 'op2' => 0 }, rows.fetch('ID_AA64ISAR0_EL1').fetch('encoding'))
    assert_includes rows.fetch('ID_AA64PFR0_EL1').fetch('fields'), { 'name' => 'SVE', 'offset' => 32, 'width' => 4 }
  end

  # An identification field is a constant field: its position is kept and its listed values
  # are not; one that overrides its access is still refused.
  def test_constant_fields_keep_their_position
    constant = lambda do |access|
      record = SysregFixture.record
      record.fetch('fieldsets').first['values'] = [
        { '_type' => 'Fields.ConstantField', 'name' => 'Low', 'access' => access,
          'rangeset' => [{ '_type' => 'Range', 'start' => 0, 'width' => 4 }],
          'value' => { '_type' => 'Values.ImplementationDefined' } },
        { '_type' => 'Fields.Reserved', 'value' => 'RES0', 'rangeset' => [{ '_type' => 'Range', 'start' => 4, 'width' => 60 }] }
      ]
      record
    end
    fields = extract([constant.call(nil)]).fetch('registers').first.fetch('fields')
    assert_equal [{ 'name' => 'Low', 'offset' => 0, 'width' => 4 }, { 'reserved' => 'RES0', 'offset' => 4, 'width' => 60 }], fields
    assert_raises(Erx::Error) { extract([constant.call({ '_type' => 'Accessors.Override' })]) }
  end

  # Each mutation of a valid specification that a consumer must not trust.
  def test_specification_refuses_bad_facts_and_policy_only_registers
    valid = JSON.parse(File.binread(File.join(REPOSITORY, Erx::Sysreg::SPECIFICATION)))
    assert Erx::Sysreg.specification(JSON.generate(valid))
    mutations = {
      'encoding out of range' => ->(spec) { spec['registers'][1]['encoding']['op0'] = 4 },
      'encoding not an integer' => ->(spec) { spec['registers'][1]['encoding']['CRn'] = 'x' },
      'fields not a list' => ->(spec) { spec['registers'][1]['fields'] = 'garbage' },
      'fields leave bits' => ->(spec) { spec['registers'][1]['fields'][0]['width'] = 63 },
      'fields out of order' => ->(spec) { spec['registers'][0]['fields'].reverse! },
      'bad reserved value' => ->(spec) { spec['registers'][0]['fields'][1]['reserved'] = 'RAZ' },
      'width not 64' => ->(spec) { spec['registers'][1]['width'] = 7 },
      'control byte in copyright' => ->(spec) { spec['registers'][1]['copyright'] = "\e]0;pwn\a" },
      'other license' => ->(spec) { spec['registers'][1]['license'] = 'MIT' },
      'other schema' => ->(spec) { spec['registers'][1]['source_version']['schema'] = '3.0' },
      'policy only' => ->(spec) { spec['registers'][1].select! { |key, _| Erx::Sysreg::POLICY_KEYS.include?(key) } },
      'unsorted' => ->(spec) { spec['registers'].reverse! }
    }
    mutations.each do |label, mutate|
      spec = JSON.parse(JSON.generate(valid))
      mutate.call(spec)
      assert_raises(Erx::Error, label) { Erx::Sysreg.specification(JSON.generate(spec)) }
    end
  end
end
