# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true
# erx-gate: sanitizers

require 'minitest/autorun'
require 'tmpdir'
require_relative '../fixtures/abi_manifest_fixture'
require_relative '../../tools/lib/erx/runner'
require_relative '../fixtures/generated_tree'

class ManifestReaderTest < Minitest::Test
  def setup
    @directory = Dir.mktmpdir('erx-manifest-reader-')
    @root = File.expand_path('../..', __dir__)
    @runner = Erx::Runner.new(owner_root: @directory, log_dir: File.join(@directory, 'logs'),
                              timeout_program: 'gtimeout')
    @driver = File.join(@directory, 'manifest-reader')
    @runner.run(['clang', '-std=c17', '-Wall', '-Wextra', '-Werror', '-pedantic',
                 '-fsanitize=address,undefined', '-fno-omit-frame-pointer',
                 *Erx::Generated.include_flags(root: @root), '-I', File.join(@root, 'include'),
                 Erx::Generated.path('liberx/generated/abi_reader.c', root: @root),
                 File.join(@root, 'test/fixtures/abi_manifest_driver.c'),
                 '-o', @driver], name: 'compile', deadline: 60)
  end

  def teardown
    FileUtils.remove_entry(@directory) if passed? && @directory && File.directory?(@directory)
  end

  def decode(bytes)
    path = File.join(@directory, 'input.bin')
    File.binwrite(path, bytes)
    record = @runner.run([@driver, path], name: 'decode', deadline: 30)
    [record.fetch('exit_status'), File.binread(record.fetch('log'))]
  rescue Erx::CommandError => error
    [error.result.fetch('exit_status'), File.binread(error.result.fetch('log'))]
  end

  def test_independent_complete_fixture
    status, output = decode(AbiManifestFixture.valid)
    assert_equal 0, status, output
    assert_equal "ok 1 0\n", output
  end

  def test_declared_length_must_match_whole_file
    bytes = AbiManifestFixture.valid
    AbiManifestFixture.integer(bytes, 8, bytes.bytesize - 1)
    status, output = decode(bytes)
    assert_equal 1, status, output
    assert_match(/error .*root.length/, output)
  end

  def test_partial_mode_requires_development
    bytes = AbiManifestFixture.valid
    AbiManifestFixture.integer(bytes, 6, 2, width: 2)
    status, output = decode(bytes)
    assert_equal 1, status, output
    assert_match(/error .*root.flags/, output)
  end

  def test_truncated_index_is_refused
    bytes = AbiManifestFixture.valid.byteslice(0, 416)
    AbiManifestFixture.integer(bytes, 8, bytes.bytesize)
    status, output = decode(bytes)
    assert_equal 1, status, output
    assert_match(/error extent principals/, output)
  end

  def test_out_of_range_string_offset_is_refused
    bytes = AbiManifestFixture.valid
    AbiManifestFixture.integer(bytes, 392, 0xffffffff)
    status, output = decode(bytes)
    assert_equal 1, status, output
    assert_match(/error string_range principals\[\].name.offset/, output)
  end

  def test_inactive_subspace_grant_is_zero
    bytes = AbiManifestFixture.valid
    AbiManifestFixture.integer(bytes, 544, 1, width: 8)
    status, output = decode(bytes)
    assert_equal 1, status, output
    assert_match(/error inactive limits\[\].spaces/, output)
  end

  def test_tagged_facet_parameters_validate_active_payloads
    assert_equal 0, decode(AbiManifestFixture.facet_parameter).first
    status, output = decode(AbiManifestFixture.facet_parameter(scalar: 2))
    assert_equal 1, status, output
    assert_match(/error range facet_parameters\[\].scalar/, output)
    status, output = decode(AbiManifestFixture.facet_parameter(kind: 6, scalar: 0, index: 1))
    assert_equal 1, status, output
    assert_match(/error index facet_parameters\[\].index/, output)
    status, output = decode(AbiManifestFixture.facet_parameter(kind: 4, scalar: 0, text: 'bad\/name'))
    assert_equal 1, status, output
    assert_match(/error string_class facet_parameters\[\].bytes.offset/, output)
    status, output = decode(AbiManifestFixture.facet_parameter(kind: 4, scalar: 0, text: 'a.b'))
    assert_equal 1, status, output
    assert_match(/error string_class facet_parameters\[\].bytes.offset/, output)
  end

  def test_session_record_is_accepted
    status, output = decode(AbiManifestFixture.session_template)
    assert_equal 0, status, output
    assert_equal "ok 1 0\n", output
  end

  def test_session_reserved_field_must_be_zero
    status, output = decode(AbiManifestFixture.session_template(reserved: 1))
    assert_equal 1, status, output
    assert_match(/error .*sessions\[\].reserved/, output)
  end

  def test_session_principal_must_exist
    status, output = decode(AbiManifestFixture.session_template(principal: 1))
    assert_equal 1, status, output
    assert_match(/error index sessions\[\].principal/, output)
  end

  # The start table: start_rows_max rows at most, each naming a principal, a
  # service or none as its display, with its reserved word zero, and none in a
  # partial boot.
  def test_start_rows_are_accepted_up_to_start_rows_max
    [1, 256].each do |count|
      status, output = decode(AbiManifestFixture.start_rows(count: count))
      assert_equal [0, "ok 1 0\n"], [status, output], "#{count} rows"
    end
  end

  def test_start_rows_beyond_start_rows_max_are_refused
    status, output = decode(AbiManifestFixture.start_rows(count: 257))
    assert_equal 1, status, output
    assert_match(/error .*starts/, output)
  end

  def test_start_row_fields_are_checked
    { { reserved: 1 } => /starts\[\].reserved/, { principal: 1 } => /index starts\[\].principal/,
      { display: 0 } => /index starts\[\].display/, { flags: 2 } => /starts\[\].flags/ }.each do |fields, error|
      status, output = decode(AbiManifestFixture.start_rows(**fields))
      assert_equal 1, status, "#{fields}: #{output}"
      assert_match(error, output, fields.to_s)
    end
  end

  def test_partial_boot_starts_no_row
    status, output = decode(AbiManifestFixture.start_rows(partial: true))
    assert_equal 1, status, output
    assert_match(/error inactive root.starts.count/, output)
  end

  def test_device_selector_refuses_inactive_fields
    bytes = AbiManifestFixture.unit_partition
    AbiManifestFixture.integer(bytes, 736 + 32, 1, width: 2)
    status, output = decode(bytes)
    assert_equal 1, status, output
    assert_match(/error inactive devices\[\].bus/, output)
  end

  def test_partial_boot_cannot_carry_domain_configuration
    bytes = AbiManifestFixture.facet_parameter
    AbiManifestFixture.integer(bytes, 6, 3, width: 2)
    status, output = decode(bytes)
    assert_equal 1, status, output
    assert_match(/error inactive root.domains.count/, output)
  end

  def test_overlapping_unit_device_spans_are_refused
    status, output = decode(AbiManifestFixture.unit_partition(overlap: true))
    assert_equal 1, status, output
    assert_match(/error partition units\[\].devices.offset/, output)
  end

  def test_unowned_device_record_is_refused
    status, output = decode(AbiManifestFixture.unit_partition(orphan: true))
    assert_equal 1, status, output
    assert_match(/error partition units\[\].devices.offset/, output)
  end
end
