# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'minitest/autorun'
require_relative '../../tools/lib/erx/abi_binary'
require_relative '../../tools/lib/erx/generated_abi'
require_relative '../fixtures/abi_manifest_fixture'

class AbiBinaryTest < Minitest::Test
  def setup
    root = File.expand_path('../..', __dir__)
    schema = Erx::ABI::Model.validate(Erx::ABI::Sources.read(root: root))
    @codec = Erx::ABI::Codec.new(schema)
  end

  def header_values
    { 'version' => 2, 'flags' => 1, 'total_size' => 4096,
      'nentries' => 1, 'entry_size' => 64, 'entries_off' => 96,
      'strings_off' => 160, 'strings_size' => 2, 'root_entry' => 0,
      'build_id' => '12345678', 'index_hash' => 'h' * 32 }
  end

  def test_pack_header_encoder_matches_independent_bytes
    expected = ["ERXPACK\0", 2, 1, 4096, 1, 64, 96, 160, 2, 0,
                '12345678', 'h' * 32].pack('a8VVQ<VVQ<Q<VVa8a32')
    original = header_values
    encoded = @codec.encode_layout('erx_pack_header', original)
    assert_equal expected, encoded
    assert encoded.frozen?
    refute original.key?('magic')
    decoded = @codec.decode_layout('erx_pack_header', expected)
    assert_equal original.merge('magic' => "ERXPACK\0"), decoded
    assert decoded.frozen?
  end

  def test_integer_width_is_checked_before_pack
    values = header_values.merge('nentries' => 1 << 32)
    error = assert_raises(Erx::ABI::DecodeError) { @codec.encode_layout('erx_pack_header', values) }
    assert_equal 'integer_range', error.reason
  end

  def test_public_version_and_enum_lookup
    assert_equal 1, @codec.abi_version
    assert_equal 3, @codec.member('prot', 'rw')
    assert_raises(Erx::ABI::DecodeError) { @codec.member('prot', 'missing') }
  end

  def test_generated_host_binding_is_self_contained_and_matches_source_model
    generated = Erx::ABI::Generated::CODEC
    assert_equal @codec.abi_version, generated.abi_version
    assert_equal @codec.schema.constants.transform_values(&:value),
                 generated.schema.constants.transform_values(&:value)
    @codec.schema.types.each do |name, type|
      assert_equal type.size, generated.schema.types.fetch(name).size, name
    end
    view = generated.open('manifest', AbiManifestFixture.valid)
    assert_equal 'root', view.string(view.fetch('principals', 0).fetch('name'))
    assert_equal @codec.encode_layout('erx_pack_header', header_values),
                 generated.encode_layout('erx_pack_header', header_values)
  end

  def test_complete_manifest_from_independent_bytes
    view = @codec.open('manifest', AbiManifestFixture.valid)
    assert_equal 1, view.count('principals')
    assert_equal 0, view.count('partial_boot')
    assert_equal 'root', view.string(view.fetch('principals', 0).fetch('name'))
    assert_equal 'node', view.string(view.header.fetch('host'))
  end

  def test_returned_view_is_independent_of_mutated_input
    bytes = AbiManifestFixture.valid
    view = @codec.open('manifest', bytes)
    bytes.replace('changed')
    assert_equal 'node', view.string(view.header.fetch('host'))
  end

  def test_partial_without_development_is_refused
    bytes = AbiManifestFixture.valid
    AbiManifestFixture.integer(bytes, 6, 2, width: 2)
    error = assert_raises(Erx::ABI::DecodeError) { @codec.open('manifest', bytes) }
    assert_equal 'flags', error.reason
    assert_equal 'root.flags', error.field
  end

  def test_length_mismatch_is_refused
    bytes = AbiManifestFixture.valid
    AbiManifestFixture.integer(bytes, 8, bytes.bytesize - 1)
    error = assert_raises(Erx::ABI::DecodeError) { @codec.open('manifest', bytes) }
    assert_equal 'length', error.reason
  end

  def test_signed_foreign_dynamic_value_decodes_without_wrap
    bytes = [-1, (1 << 64) - 1].pack('q<Q<')
    result = @codec.decode_layout('erx_elf64_dyn', bytes)
    assert_equal(-1, result.fetch('d_tag'))
    assert_equal((1 << 64) - 1, result.fetch('d_value'))
  end

  def test_unit_spans_partition_the_device_table
    view = @codec.open('manifest', AbiManifestFixture.unit_partition)
    assert_equal 2, view.count('units')
    assert_equal 2, view.count('devices')
    assert_refused %w[partition units[].devices.offset], AbiManifestFixture.unit_partition(overlap: true)
    assert_refused %w[partition units[].devices.offset], AbiManifestFixture.unit_partition(orphan: true)
  end

  def test_tagged_parameter_checks_its_own_payload_contract
    @codec.open('manifest', AbiManifestFixture.facet_parameter)
    assert_raises(Erx::ABI::DecodeError) do
      @codec.open('manifest', AbiManifestFixture.facet_parameter(scalar: 2))
    end
    assert_raises(Erx::ABI::DecodeError) do
      @codec.open('manifest', AbiManifestFixture.facet_parameter(kind: 6, scalar: 0, index: 1))
    end
    assert_raises(Erx::ABI::DecodeError) do
      @codec.open('manifest', AbiManifestFixture.facet_parameter(kind: 4, scalar: 0, text: 'bad/name'))
    end
  end

  # The first device row is at 720: after the header and two 24-byte unit rows.
  def test_device_selector_refuses_inactive_fields_and_missing_path
    bytes = AbiManifestFixture.unit_partition
    AbiManifestFixture.integer(bytes, 720 + 32, 1, width: 2)
    assert_refused %w[inactive devices[].bus], bytes
    bytes = AbiManifestFixture.unit_partition
    AbiManifestFixture.span(bytes, 720 + 8, 0, 0)
    assert_refused %w[string_range devices[].path.offset], bytes
    bytes = AbiManifestFixture.unit_partition
    AbiManifestFixture.integer(bytes, 720 + 48, 4096, width: 8)
    assert_refused %w[inactive devices[].dma_memory], bytes
  end

  # A refusal for any other reason, such as a table at the wrong offset, would hide
  # whether the check under test still bites.
  def assert_refused((reason, field), bytes)
    error = assert_raises(Erx::ABI::DecodeError) { @codec.open('manifest', bytes) }
    assert_equal [reason, field], [error.reason, error.field], error.message
  end

  def test_partial_mode_cannot_carry_configured_domain_tables
    bytes = AbiManifestFixture.facet_parameter
    AbiManifestFixture.integer(bytes, 6, 3, width: 2)
    assert_raises(Erx::ABI::DecodeError) { @codec.open('manifest', bytes) }
  end
end
