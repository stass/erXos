# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'minitest/autorun'
require 'tmpdir'
require_relative '../fixtures/pack_fixture'
require_relative '../../tools/lib/erx/abi'
require_relative '../../tools/lib/erx/abi_binary'
require_relative '../../tools/lib/erx/pack_wire'

class PackWireTest < Minitest::Test
  def setup
    @root = File.expand_path('../..', __dir__)
    @codec = Erx::ABI::Codec.new(Erx::ABI::Generator.plan(root: @root).schema)
    @directory = Dir.mktmpdir('pack-wire-')
    @writer = Erx::PackWire.new(codec: @codec)
  end

  def teardown
    FileUtils.remove_entry(@directory)
  end

  def rows
    [['system/manifest', AbiManifestFixture.valid, 1], ['system/root', PackFixture.image, 2]].map do |path, bytes, kind|
      snapshot = File.join(@directory, File.basename(path))
      File.binwrite(snapshot, bytes)
      { 'path' => path, 'kind' => kind, 'flags' => 1, 'size' => bytes.bytesize, 'snapshot' => snapshot }
    end
  end

  def test_canonical_bytes_match_independent_raw_format_oracle
    path = File.join(@directory, 'wire')
    File.open(path, 'wb') do |output|
      @writer.write(rows: rows, root_entry: 1, build_kind: 'development', output: output, budget: 1_048_576)
    end
    actual = File.binread(path)
    expected = PackFixture.valid
    # The independent wire fixture deliberately leaves build_id blank. Its
    # normative offset is 56; the remaining complete wire bytes must agree.
    expected[56, 8] = actual.byteslice(56, 8)
    assert_equal expected, actual
  end

  def test_budget_refusal_precedes_the_first_output_byte
    File.open(File.join(@directory, 'wire'), 'wb') do |output|
      assert_raises(Erx::Error) do
        @writer.write(rows: rows, root_entry: 1, build_kind: 'development', output: output, budget: 8192)
      end
      assert_equal 0, output.pos
    end
  end

  def test_short_snapshot_is_a_typed_refusal
    entries = rows
    File.binwrite(entries.first.fetch('snapshot'), 'short')
    File.open(File.join(@directory, 'wire'), 'wb') do |output|
      assert_raises(Erx::Error) do
        @writer.write(rows: entries, root_entry: 1, build_kind: 'development', output: output, budget: 1_048_576)
      end
    end
  end

  def test_root_selection_changes_build_identity
    entries = rows
    entries << entries.last.merge('path' => 'system/root2')
    images = [1, 2].map do |root|
      path = File.join(@directory, "root-#{root}")
      File.open(path, 'wb') do |output|
        @writer.write(rows: entries, root_entry: root, build_kind: 'development', output: output, budget: 1_048_576)
      end
      File.binread(path)
    end
    refute_equal images.first, images.last
    # Normative independent header offset/size, not the production schema.
    refute_equal images.first.byteslice(56, 8), images.last.byteslice(56, 8)
  end

  def test_build_identity_matches_an_independent_complete_wire_digest
    path = File.join(@directory, 'identity')
    File.open(path, 'wb') do |output|
      @writer.write(rows: rows, root_entry: 1, build_kind: 'development', output: output, budget: 1_048_576)
    end
    bytes = File.binread(path)
    identity = bytes.byteslice(56, 8)
    bytes[56, 8] = "\0".b * 8
    assert_equal Digest::SHA256.digest(bytes).byteslice(0, 8), identity
  end

  def test_nonzero_output_position_is_refused_before_effects
    path = File.join(@directory, 'prefixed')
    File.open(path, 'wb') do |output|
      output.write('prefix')
      assert_raises(Erx::Error) do
        @writer.write(rows: rows, root_entry: 1, build_kind: 'development', output: output, budget: 1_048_576)
      end
      assert_equal 6, output.pos
    end
    assert_equal 'prefix', File.binread(path)
  end
end
