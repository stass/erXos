# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true
# erx-gate: sanitizers

require 'minitest/autorun'
require 'tmpdir'
require_relative '../fixtures/abi_manifest_fixture'
require_relative '../../tools/lib/erx/runner'

class ManifestReaderTest < Minitest::Test
  def setup
    @directory = Dir.mktmpdir('erx-manifest-reader-')
    @root = File.expand_path('../..', __dir__)
    @runner = Erx::Runner.new(owner_root: @directory, log_dir: File.join(@directory, 'logs'),
                              timeout_program: 'gtimeout')
    @driver = File.join(@directory, 'manifest-reader')
    @runner.run(['clang', '-std=c17', '-Wall', '-Wextra', '-Werror', '-pedantic',
                 '-fsanitize=address,undefined', '-fno-omit-frame-pointer',
                 '-I', File.join(@root, 'include'),
                 File.join(@root, 'liberx/generated/abi_reader.c'),
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
    bytes = AbiManifestFixture.valid.byteslice(0, 400)
    AbiManifestFixture.integer(bytes, 8, bytes.bytesize)
    status, output = decode(bytes)
    assert_equal 1, status, output
    assert_match(/error extent principals/, output)
  end

  def test_out_of_range_string_offset_is_refused
    bytes = AbiManifestFixture.valid
    AbiManifestFixture.integer(bytes, 376, 0xffffffff)
    status, output = decode(bytes)
    assert_equal 1, status, output
    assert_match(/error string_range principals\[\].name.offset/, output)
  end

  def test_inactive_subspace_grant_is_zero
    bytes = AbiManifestFixture.valid
    AbiManifestFixture.integer(bytes, 528, 1, width: 8)
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
  end

  def test_device_selector_refuses_inactive_fields
    bytes = AbiManifestFixture.unit_partition
    AbiManifestFixture.integer(bytes, 720 + 32, 1, width: 2)
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
