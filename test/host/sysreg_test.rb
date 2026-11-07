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
      assert_raises(Erx::Error) { Erx::Sysreg.refresh(root: root) }
    end
  end

  def test_cli_verifies_and_refreshes_a_given_tree
    with_synthetic_tree do |root|
      runner = Erx::Runner.new(owner_root: root, log_dir: File.join(root, 'logs'))
      command = [RbConfig.ruby, File.join(REPOSITORY, 'tools/erx'), 'sysreg', 'refresh', '--root', root]
      assert_raises(Erx::CommandError) { runner.run(command + ['--verify'], name: 'stale-sysreg', deadline: 60) }
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

  # The checked-in specification is an input every build can read without
  # Arm's archive; these are the counter facts the kernel relies on.
  def test_checked_in_specification_parses_with_counter_facts
    bytes = File.binread(File.join(REPOSITORY, Erx::Sysreg::SPECIFICATION))
    assert_equal %w[CNTFRQ_EL0 CNTPCT_EL0 CNTVCT_EL0],
                 Erx::Sysreg.selection(bytes).fetch('registers').map { |register| register.fetch('name') }
    rows = JSON.parse(bytes).fetch('registers').to_h { |register| [register.fetch('name'), register] }
    assert_equal({ 'op0' => 3, 'op1' => 3, 'CRn' => 14, 'CRm' => 0, 'op2' => 2 }, rows.fetch('CNTVCT_EL0').fetch('encoding'))
    assert_equal [{ 'name' => 'VirtualCount', 'offset' => 0, 'width' => 64 }], rows.fetch('CNTVCT_EL0').fetch('fields')
    assert_equal({ 'name' => 'ClockFreq', 'offset' => 0, 'width' => 32 }, rows.fetch('CNTFRQ_EL0').fetch('fields').first)
  end

  # Needs Arm's archive (tools/erx fetch --source arm-registers), which neither
  # setup nor `make check` downloads.
  def test_checked_in_specification_matches_the_pinned_arm_source
    unless File.file?(File.join(REPOSITORY, Erx::Sysreg::SOURCE))
      skip "Arm's archive is not fetched; run tools/erx fetch --source arm-registers to verify #{Erx::Sysreg::SPECIFICATION}"
    end
    assert Erx::Sysreg.verify(root: REPOSITORY)
  end
end
