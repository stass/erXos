# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'minitest/autorun'
require_relative '../../tools/lib/erx/abi'
require_relative '../../tools/lib/erx/abi_binary'
require_relative '../../tools/lib/erx/elf_plan'

class ElfBoundaryTest < Minitest::Test
  def setup
    root = File.expand_path('../..', __dir__)
    @codec = Erx::ABI::Codec.new(Erx::ABI::Generator.plan(root: root).schema)
    @plan = { 'abi_version' => 1, 'virtual_origin' => 65536, 'fixed_base' => 65536, 'span' => 4096,
              'entry' => 64, 'phdr_offset' => 0, 'output_size' => 8192,
              'flags' => 1, 'phnum' => 1, 'base_alignment' => 4096,
              'loads' => [{ 'source_offset' => 0, 'file_offset' => 4096, 'mem_offset' => 0,
                            'file_size' => 128, 'mem_size' => 128, 'prot' => 5, 'flags' => 0 }] }
  end

  def decode(value = @plan)
    Erx::ElfPlanner.decode(JSON.generate(value), codec: @codec, source_size: 4096, budget: 8192)
  end

  def test_complete_bounded_reply_is_immutable
    plan = decode
    assert_equal 8192, plan.fetch('output_size')
    assert plan.frozen?
    assert plan.fetch('loads').frozen?
    assert plan.fetch('loads').first.frozen?
  end

  def test_reply_without_producer_abi_version_is_refused
    assert_raises(Erx::Error) { decode(@plan.reject { |key, _| key == 'abi_version' }) }
    assert_raises(Erx::Error) { decode(@plan.merge('abi_version' => 2)) }
  end

  def test_unknown_missing_nonnumeric_and_negative_fields_are_refused
    altered = Marshal.load(Marshal.dump(@plan))
    altered['unknown'] = 0
    assert_raises(Erx::Error) { decode(altered) }
    @plan.keys.each do |key|
      altered = @plan.reject { |field, _| field == key }
      assert_raises(Erx::Error) { decode(altered) }
    end
    [nil, false, -1, 1.5, '1', [], {}, 1 << 64].each do |bad|
      assert_raises(Erx::Error) { decode(@plan.merge('entry' => bad)) }
    end
  end

  def test_segment_source_virtual_and_storage_extents_are_checked
    [{ 'source_offset' => 4096 }, { 'file_size' => 129 }, { 'mem_size' => 0 },
     { 'mem_offset' => 4096 }, { 'file_offset' => 0 }, { 'prot' => 7 },
     { 'flags' => 1 }].each do |change|
      load = @plan.fetch('loads').first.merge(change)
      assert_raises(Erx::Error) { decode(@plan.merge('loads' => [load])) }
    end
    assert_raises(Erx::Error) { decode(@plan.merge('output_size' => 4096)) }
    assert_raises(Erx::Error) { decode(@plan.merge('loads' => [])) }
    assert_raises(Erx::Error) { decode(@plan.merge('loads' => @plan.fetch('loads') * 17)) }
  end

  def test_json_duplicate_keys_invalid_utf8_and_huge_input_are_refused
    ["{\"loads\":[],\"loads\":[]}", "\xff".b, ' ' * 32_769].each do |bytes|
      assert_raises(Erx::Error) do
        Erx::ElfPlanner.decode(bytes, codec: @codec, source_size: 4096, budget: 8192)
      end
    end
  end
end
