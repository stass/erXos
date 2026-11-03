# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'minitest/autorun'
require 'rbconfig'
require_relative '../../tools/lib/erx/sysreg'
require_relative '../fixtures/sysreg_fixture'

class SysregTest < Minitest::Test
  def test_extractor_drift_includes_missing_modified_and_orphaned_output
    repository = File.expand_path('../..', __dir__)
    Dir.mktmpdir('erx-sysreg-drift-') do |root|
      FileUtils.mkdir_p(File.join(root, 'hw/sysreg'))
      FileUtils.mkdir_p(File.join(root, 'build/third_party/arm-registers'))
      bytes = JSON.generate([SysregFixture.record])
      File.binwrite(File.join(root, 'build/third_party/arm-registers/Registers.json'), bytes)
      File.binwrite(File.join(root, 'hw/sysreg/aarch64-policy.json'), JSON.generate(SysregFixture.policy(bytes)))
      runner = Erx::Runner.new(owner_root: root, log_dir: File.join(root, 'logs'))
      command = [RbConfig.ruby, File.join(repository, 'tools/sysreg_extract.rb'), '--root', root]
      assert_raises(Erx::CommandError) { runner.run(command + ['--check'], name: 'missing-sysreg', deadline: 30) }
      runner.run(command, name: 'generate-sysreg', deadline: 30)
      runner.run(command + ['--check'], name: 'check-sysreg', deadline: 30)
      File.open(File.join(root, 'hw/sysreg/aarch64.json'), 'ab') { |file| file.write(' ') }
      assert_raises(Erx::CommandError) { runner.run(command + ['--check'], name: 'modified-sysreg', deadline: 30) }
      runner.run(command, name: 'regenerate-sysreg', deadline: 30)
      File.binwrite(File.join(root, 'hw/sysreg/orphan.json'), '{}')
      assert_raises(Erx::CommandError) { runner.run(command + ['--check'], name: 'orphan-sysreg', deadline: 30) }
    end
  end

  def test_nonregular_source_is_rejected_without_waiting_for_a_writer
    repository = File.expand_path('../..', __dir__)
    Dir.mktmpdir('erx-sysreg-fifo-') do |root|
      FileUtils.mkdir_p(File.join(root, 'hw/sysreg'))
      FileUtils.mkdir_p(File.join(root, 'build/third_party/arm-registers'))
      bytes = JSON.generate([SysregFixture.record])
      File.binwrite(File.join(root, 'hw/sysreg/aarch64-policy.json'), JSON.generate(SysregFixture.policy(bytes)))
      runner = Erx::Runner.new(owner_root: root, log_dir: File.join(root, 'logs'))
      runner.run(['mkfifo', File.join(root, 'build/third_party/arm-registers/Registers.json')], name: 'fifo-source', deadline: 5)
      error = assert_raises(Erx::CommandError) do
        runner.run([RbConfig.ruby, File.join(repository, 'tools/sysreg_extract.rb'), '--root', root],
                   name: 'nonregular-sysreg', deadline: 1)
      end
      assert_equal 'failed', error.result.fetch('state')
      assert_equal 1, error.result.fetch('exit_status')
    end
  end

  def extract(records)
    bytes = JSON.generate(records)
    declaration = Erx::Sysreg.policy(JSON.generate(SysregFixture.policy(bytes)))
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
    declaration = Erx::Sysreg.policy(JSON.generate(SysregFixture.policy(bytes)))
    assert_raises(Erx::Error) { Erx::Sysreg.extract(bytes + ' ', declaration: declaration) }
    bad_policy = SysregFixture.policy(bytes)
    bad_policy.fetch('registers').first['write'] = true
    assert_raises(Erx::Error) { Erx::Sysreg.policy(JSON.generate(bad_policy)) }
  end

  def test_pinned_arm_extraction_matches_checked_data_and_counter_facts
    root = File.expand_path('../..', __dir__)
    bytes = Erx::Sysreg.extract_file(source: File.join(root, 'build/third_party/arm-registers/Registers.json'),
                                    policy_path: File.join(root, 'hw/sysreg/aarch64-policy.json'))
    assert_equal File.binread(File.join(root, 'hw/sysreg/aarch64.json')), bytes
    rows = JSON.parse(bytes).fetch('registers').to_h { |register| [register.fetch('name'), register] }
    assert_equal({ 'op0' => 3, 'op1' => 3, 'CRn' => 14, 'CRm' => 0, 'op2' => 2 }, rows.fetch('CNTVCT_EL0').fetch('encoding'))
    assert_equal [{ 'name' => 'VirtualCount', 'offset' => 0, 'width' => 64 }], rows.fetch('CNTVCT_EL0').fetch('fields')
    assert_equal({ 'name' => 'ClockFreq', 'offset' => 0, 'width' => 32 }, rows.fetch('CNTFRQ_EL0').fetch('fields').first)
  end
end
