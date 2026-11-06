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
  # The hashing program, compiled here rather than through PackTools.
  Program = Struct.new(:path) do
    def run(arguments, runner:, name:, deadline:)
      runner.run([path, *arguments], name: name, deadline: deadline)
    end
  end

  def setup
    @root = File.expand_path('../..', __dir__)
    @codec = Erx::ABI::Codec.new(Erx::ABI::Generator.plan(root: @root).schema)
    @directory = Dir.mktmpdir('pack-wire-')
    @runner = Erx::Runner.new(owner_root: @directory, log_dir: File.join(@directory, 'logs'))
    program = File.join(@directory, 'pack-hash')
    blake3 = File.join(@root, 'kernel/crypto/blake3')
    @runner.run(['clang', '-std=c17', '-Wall', '-Wextra', '-Werror', '-pedantic', '-O1',
                 '-I', File.join(@root, 'include'), '-I', File.join(@root, 'kernel/crypto'),
                 File.join(blake3, 'blake3.c'), File.join(blake3, 'blake3_portable.c'),
                 File.join(@root, 'tools/host/input.c'), File.join(@root, 'tools/host/pack_hash.c'),
                 '-o', program], name: 'compile-pack-hash', deadline: 60)
    hasher = Erx::PackHasher.new(helper: Program.new(program), runner: @runner)
    @writer = Erx::PackWire.new(codec: @codec, hasher: hasher)
  end

  def teardown
    FileUtils.remove_entry(@directory) if passed?
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
    # The independent wire fixture leaves build_id blank. Its normative
    # offset is 56; with it copied and the index hash recomputed by b3sum,
    # every byte must agree, the file hashes included.
    expected[56, 8] = actual.byteslice(56, 8)
    assert_equal PackFixture.rehash(expected, files: false), actual
  end

  # A test image marks itself in the header's flags, beside the development bit: only a
  # development build carries test code, and nothing else sets the mark.
  def test_test_code_is_marked_only_in_a_development_build
    flags = lambda do |**options|
      path = File.join(@directory, 'wire')
      File.open(path, 'wb') do |output|
        @writer.write(rows: rows, root_entry: 1, build_kind: 'development', output: output, budget: 1_048_576, **options)
      end
      File.binread(path, 4, 12).unpack1('V')
    end
    assert_equal @codec.member('pack_flags', 'development'), flags.call
    assert_equal @codec.member('pack_flags', 'development') | @codec.member('pack_flags', 'test_code'),
                 flags.call(test_code: true)
    File.open(File.join(@directory, 'release'), 'wb') do |output|
      error = assert_raises(Erx::Error) do
        @writer.write(rows: rows, root_entry: 1, build_kind: 'release', output: output, budget: 1_048_576, test_code: true)
      end
      assert_match(/test code/, error.message)
      assert_equal 0, output.pos
    end
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

  def test_build_identity_is_the_index_hash_with_both_identity_fields_zero
    path = File.join(@directory, 'identity')
    File.open(path, 'wb') do |output|
      @writer.write(rows: rows, root_entry: 1, build_kind: 'development', output: output, budget: 1_048_576)
    end
    bytes = File.binread(path)
    identity = bytes.byteslice(56, 8)
    bytes[56, 40] = "\0".b * 40
    assert_equal PackFixture.b3sum([bytes.byteslice(0, 4096)]).first.byteslice(0, 8), identity
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
