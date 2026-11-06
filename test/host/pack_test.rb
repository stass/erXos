# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true
# erx-gate: sanitizers

require 'minitest/autorun'
require 'tmpdir'
require_relative '../fixtures/pack_fixture'
require_relative '../../tools/lib/erx/runner'

class PackTest < Minitest::Test
  def setup
    @directory = Dir.mktmpdir('erx-pack-')
    @root = File.expand_path('../..', __dir__)
    @runner = Erx::Runner.new(owner_root: @directory, log_dir: File.join(@directory, 'logs'))
    @checker = File.join(@directory, 'pack-check')
    sanitizers = ENV.fetch('ERX_SANITIZERS', '').split(',').reject(&:empty?)
    unless (sanitizers - %w[address undefined]).empty?
      raise Erx::Error, 'unsupported pack-test sanitizer'
    end
    flags = sanitizers.empty? ? [] : ["-fsanitize=#{sanitizers.join(',')}", '-fno-omit-frame-pointer']
    @runner.run(['clang', '-std=c17', '-Wall', '-Wextra', '-Werror', '-pedantic', '-O1', '-g',
                 *flags, '-I', File.join(@root, 'include'), '-I', File.join(@root, 'kernel/crypto'),
                 File.join(@root, 'kernel/core/pack.c'),
                 File.join(@root, 'kernel/crypto/blake3/blake3.c'),
                 File.join(@root, 'kernel/crypto/blake3/blake3_portable.c'),
                 File.join(@root, 'liberx/generated/abi_reader.c'),
                 File.join(@root, 'tools/host/input.c'),
                 File.join(@root, 'tools/host/pack_check.c'), '-o', @checker],
                name: 'compile-pack', deadline: 60)
  end

  def teardown
    FileUtils.remove_entry(@directory) if passed? && File.directory?(@directory)
  end

  def check(bytes)
    path = File.join(@directory, 'input.pack')
    File.binwrite(path, bytes)
    command = @runner.run([@checker, path], name: 'check-pack', deadline: 30)
    [command.fetch('exit_status'), File.read(command.fetch('log'))]
  rescue Erx::CommandError => error
    [error.result.fetch('exit_status'), File.read(error.result.fetch('log'))]
  end

  def reject(bytes, reason)
    status, output = check(bytes)
    assert_equal 1, status, output
    assert_match(/error #{Regexp.escape(reason)} /, output)
  end

  def test_independent_valid_image
    status, output = check(PackFixture.valid)
    assert_equal 0, status, output
    assert_equal "ok 2\n", output
  end

  def test_nonadjacent_file_prefix_is_refused
    reject(PackFixture.valid(paths: ['a', 'a-foo', 'a/b', 'system/root']), 'file_prefix')
  end

  def test_similar_paths_without_file_prefix_are_valid
    status, output = check(PackFixture.valid(paths: ['a', 'a-foo', 'ab/c', 'system/root']))
    assert_equal 0, status, output
  end

  def test_duplicate_and_unsorted_paths_are_refused
    reject(PackFixture.valid(paths: ['a', 'a', 'system/root']), 'path_order')
    reject(PackFixture.valid(paths: ['b', 'a', 'system/root']), 'path_order')
  end

  def test_path_components_and_invalid_utf8_are_refused
    ['/a', 'a/', 'a//b', './a', 'a/../b', "a\0b".b, "a\xc0\xaf".b,
     "a\xed\xa0\x80".b, "a\xf4\x90\x80\x80".b].each do |name|
      reject(PackFixture.valid(paths: [name, 'system/root']), 'path')
    end
  end

  def test_changed_magic_and_noncanonical_table_are_refused
    bytes = PackFixture.valid
    bytes[0] = 'x'
    reject(bytes, 'magic')
    bytes = PackFixture.valid
    PackFixture.integer(bytes, 32, 4096, width: 8)
    reject(PackFixture.rehash(bytes), 'header_values')
  end

  def test_file_cannot_overlap_the_index
    bytes = PackFixture.valid
    PackFixture.integer(bytes, PackFixture.entry_offset(0) + 8, 0, width: 8)
    reject(PackFixture.rehash(bytes), 'entry_values')
  end

  def test_nonzero_archive_padding_is_refused
    bytes = PackFixture.valid
    bytes[1000] = 'x'
    reject(PackFixture.rehash(bytes), 'index_padding')
  end

  def test_root_must_be_system_executable_without_jit
    bytes = PackFixture.valid
    root = bytes.byteslice(52, 4).unpack1('V')
    PackFixture.integer(bytes, PackFixture.entry_offset(root) + 7, 0, width: 1)
    reject(PackFixture.rehash(bytes), 'release_run')
    bytes = PackFixture.valid
    PackFixture.integer(bytes, PackFixture.root_offset(bytes) + 12, 2)
    reject(PackFixture.rehash(bytes), 'image_header')
  end

  def test_image_cannot_map_manifest_or_nonzero_tail
    bytes = PackFixture.valid
    PackFixture.integer(bytes, PackFixture.root_offset(bytes) + 56, 0, width: 8)
    reject(PackFixture.rehash(bytes), 'image_segment_range')
    bytes = PackFixture.valid
    bytes[PackFixture.root_offset(bytes) + 4096 + 128] = 'x'
    reject(PackFixture.rehash(bytes), 'image_payload')
  end

  def test_entry_and_complete_phdr_range_must_be_mapped
    bytes = PackFixture.valid
    PackFixture.integer(bytes, PackFixture.root_offset(bytes) + 32, 128, width: 8)
    reject(PackFixture.rehash(bytes), 'image_entry_or_phdr')
    bytes = PackFixture.valid
    PackFixture.integer(bytes, PackFixture.root_offset(bytes) + 40, 100, width: 8)
    reject(PackFixture.rehash(bytes), 'image_entry_or_phdr')
  end

  def test_image_virtual_span_and_flags_are_checked
    bytes = PackFixture.valid
    PackFixture.integer(bytes, PackFixture.root_offset(bytes) + 16, 8192, width: 8)
    reject(PackFixture.rehash(bytes), 'image_entry_or_phdr')
    bytes = PackFixture.valid
    PackFixture.integer(bytes, PackFixture.root_offset(bytes) + 56 + 32, 7)
    reject(PackFixture.rehash(bytes), 'image_segment_range')
  end

  def test_zero_file_writable_segment_has_no_stored_pages
    image = PackFixture.image
    PackFixture.integer(image, 6, 2, width: 2)
    PackFixture.integer(image, 16, 8192, width: 8)
    image[96, 40] = [8192, 4096, 0, 4096, 3, 0].pack('Q<4V2')
    status, output = check(PackFixture.valid(image_bytes: image))
    assert_equal 0, status, output
    PackFixture.integer(image, 96 + 8, 0, width: 8)
    reject(PackFixture.valid(image_bytes: image), 'image_segment_range')
  end

  def test_readonly_anonymous_tail_is_stored_and_zero
    image = PackFixture.image + ("\0".b * 4096)
    PackFixture.integer(image, 6, 2, width: 2)
    PackFixture.integer(image, 16, 8192, width: 8)
    image[96, 40] = [8192, 4096, 0, 4096, 1, 0].pack('Q<4V2')
    status, output = check(PackFixture.valid(image_bytes: image))
    assert_equal 0, status, output
    image[8192] = 'x'
    reject(PackFixture.valid(image_bytes: image), 'image_payload')
  end

  def test_manifest_and_pack_build_kinds_must_agree
    manifest = AbiManifestFixture.valid
    PackFixture.integer(manifest, 6, 0, width: 2)
    reject(PackFixture.valid(manifest_bytes: manifest), 'manifest_flags')
    bytes = PackFixture.valid
    PackFixture.integer(bytes, 12, 0)
    reject(PackFixture.rehash(bytes), 'manifest_flags')
  end

  # A test image marks itself, and only a development build may be one.
  def test_test_code_marks_only_a_development_build
    status, output = check(mutated { |bytes| PackFixture.integer(bytes, 12, 5) })
    assert_equal 0, status, output
    reject(mutated { |bytes| PackFixture.integer(bytes, 12, 4) }, 'header_values')
    reject(mutated { |bytes| PackFixture.integer(bytes, 12, 6) }, 'header_values')
  end

  def test_system_release_cannot_be_split_by_an_unmarked_file
    bytes = PackFixture.valid(paths: ['a', 'b', 'system/root'])
    PackFixture.integer(bytes, PackFixture.entry_offset(0) + 7, 1, width: 1)
    reject(PackFixture.rehash(bytes), 'release_run')
  end

  # Damage anywhere in the index run is refused by the index hash before
  # any structural check runs; the same damage with the hash recomputed is
  # refused by the check it breaks, so the hash check is what refused first.
  def test_index_hash_is_checked_before_any_entry
    strings = PackFixture.field(PackFixture.valid, 40, 8)
    [PackFixture.entry_offset(0) + 8, strings, 1000].each do |offset|
      bytes = PackFixture.valid
      bytes.setbyte(offset, bytes.getbyte(offset) ^ 1)
      reject(bytes, 'index_hash')
    end
    bytes = PackFixture.valid
    bytes.setbyte(PackFixture.entry_offset(0) + 8, bytes.getbyte(PackFixture.entry_offset(0) + 8) ^ 1)
    reject(PackFixture.rehash(bytes, files: false), 'entry_values')
  end

  # The validator reads no file data: a flipped data byte passes it and
  # fails that file's check alone, naming its entry.
  def test_damaged_file_fails_its_own_check
    bytes = PackFixture.valid(paths: ['a', 'system/root'])
    data = PackFixture.field(bytes, PackFixture.entry_offset(0) + 8, 8)
    bytes.setbyte(data, bytes.getbyte(data) ^ 1)
    reject(bytes, 'file_hash')
    assert_match(/error file_hash 0\n/, check(bytes).last)
  end

  def test_file_padding_must_be_zero_whatever_the_hash
    bytes = PackFixture.valid(paths: ['a', 'system/root'])
    data = PackFixture.field(bytes, PackFixture.entry_offset(0) + 8, 8)
    bytes[data + 1] = 'x'
    reject(PackFixture.rehash(bytes), 'padding')
  end

  def mutated(paths: ['system/root'])
    bytes = PackFixture.valid(paths: paths)
    yield bytes
    PackFixture.rehash(bytes)
  end

  def flags_of(index) = PackFixture.entry_offset(index) + 7

  def test_archive_length_must_equal_the_header_and_the_last_run
    bytes = PackFixture.valid
    reject(bytes.byteslice(0, bytes.bytesize - 4096), 'header_values')
    reject(bytes + ("\0".b * 4096), 'header_values')
    cut = bytes.byteslice(0, bytes.bytesize - 4096)
    PackFixture.integer(cut, 16, cut.bytesize, width: 8)
    reject(PackFixture.rehash(cut, files: false), 'entry_values')
    long = bytes + ("\0".b * 4096)
    PackFixture.integer(long, 16, long.bytesize, width: 8)
    reject(PackFixture.rehash(long, files: false), 'archive_end')
  end

  def test_header_bounds
    reject(mutated { |bytes| PackFixture.integer(bytes, 52, 2) }, 'header_values')
    reject(mutated { |bytes| PackFixture.integer(bytes, 12, 9) }, 'header_values')
    reject(mutated { |bytes| PackFixture.integer(bytes, 24, 65_537) }, 'header_values')
    reject(mutated { |bytes| PackFixture.integer(bytes, 28, 32) }, 'header_values')
  end

  def test_the_system_configuration_must_be_a_system_file
    missing = mutated { |bytes| bytes[PackFixture.field(bytes, 40, 8) + 14] = 'e' }
    reject(missing, 'archive_end')
    reject(mutated { |bytes| PackFixture.integer(bytes, flags_of(0), 0, width: 1) }, 'manifest_binding')
    reject(mutated { |bytes| PackFixture.integer(bytes, flags_of(0) - 1, 2, width: 1) }, 'manifest_binding')
  end

  def test_system_and_seal_marks
    reject(mutated { |bytes| PackFixture.integer(bytes, flags_of(1), 3, width: 1) }, 'entry_values')
    reject(mutated { |bytes| PackFixture.integer(bytes, flags_of(1), 5, width: 1) }, 'entry_values')
    split = mutated(paths: ['a', 'b', 'c', 'system/root']) do |bytes|
      PackFixture.integer(bytes, flags_of(0), 2, width: 1)
      PackFixture.integer(bytes, flags_of(2), 2, width: 1)
    end
    reject(split, 'release_run')
    one_run = mutated(paths: ['a', 'b', 'c', 'system/root']) do |bytes|
      PackFixture.integer(bytes, flags_of(0), 2, width: 1)
      PackFixture.integer(bytes, flags_of(1), 2, width: 1)
    end
    assert_equal 0, check(one_run).first
  end

  def test_entry_values_and_the_string_table
    reject(mutated { |bytes| PackFixture.integer(bytes, PackFixture.entry_offset(0) + 24, 1, width: 8) }, 'entry_values')
    reject(mutated { |bytes| PackFixture.integer(bytes, PackFixture.entry_offset(0) + 6, 3, width: 1) }, 'entry_values')
    reject(mutated { |bytes| PackFixture.integer(bytes, PackFixture.entry_offset(1), 1 << 31) }, 'path_extent')
    reject(mutated { |bytes| PackFixture.integer(bytes, PackFixture.entry_offset(1), 0) }, 'path_extent')
    slack = mutated { |bytes| PackFixture.integer(bytes, 48, PackFixture.field(bytes, 48, 4) + 1) }
    reject(slack, 'path_extent')
  end

  def test_empty_files_in_the_table_and_at_its_end
    bytes = PackFixture.valid(paths: ['a', 'system/root', 'z'], file_bytes: ''.b)
    status, output = check(bytes)
    assert_equal [0, "ok 4\n"], [status, output]
    last = PackFixture.entry_offset(3)
    assert_equal bytes.bytesize, PackFixture.field(bytes, last + 8, 8)
    assert_equal 0, PackFixture.field(bytes, last + 16, 8)
  end

  def test_other_versions_are_refused_with_a_diagnostic
    version_one = PackFixture.valid
    version_one[0, 64] = ["ERXPACK\0".b, 1, 1, version_one.bytesize, 2, 32, 64, 128, 26, 1,
                          "\0" * 8].pack('a8VVQ<VVQ<Q<VVa8')
    status, output = check(version_one)
    assert_equal [1, "error version 1, expected 2 4294967295\n"], [status, output]
    bytes = PackFixture.valid
    PackFixture.integer(bytes, 8, 3)
    status, output = check(PackFixture.rehash(bytes))
    assert_equal [1, "error version 3, expected 2 4294967295\n"], [status, output]
  end
end
