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
                 *flags, '-I', File.join(@root, 'include'),
                 File.join(@root, 'kernel/core/pack.c'),
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
    reject(bytes, 'header_values')
  end

  def test_file_cannot_overlap_the_index
    bytes = PackFixture.valid
    PackFixture.integer(bytes, 64 + 8, 0, width: 8)
    reject(bytes, 'entry_values')
  end

  def test_nonzero_archive_padding_is_refused
    bytes = PackFixture.valid
    bytes[1000] = 'x'
    reject(bytes, 'index_extent')
  end

  def test_root_must_be_system_executable_without_jit
    bytes = PackFixture.valid
    root = bytes.byteslice(52, 4).unpack1('V')
    PackFixture.integer(bytes, 64 + root * 32 + 7, 0, width: 1)
    reject(bytes, 'release_run')
    bytes = PackFixture.valid
    PackFixture.integer(bytes, PackFixture.root_offset(bytes) + 12, 2)
    reject(bytes, 'image_header')
  end

  def test_image_cannot_map_manifest_or_nonzero_tail
    bytes = PackFixture.valid
    PackFixture.integer(bytes, PackFixture.root_offset(bytes) + 56, 0, width: 8)
    reject(bytes, 'image_segment_range')
    bytes = PackFixture.valid
    bytes[PackFixture.root_offset(bytes) + 4096 + 128] = 'x'
    reject(bytes, 'image_payload')
  end

  def test_entry_and_complete_phdr_range_must_be_mapped
    bytes = PackFixture.valid
    PackFixture.integer(bytes, PackFixture.root_offset(bytes) + 32, 128, width: 8)
    reject(bytes, 'image_entry_or_phdr')
    bytes = PackFixture.valid
    PackFixture.integer(bytes, PackFixture.root_offset(bytes) + 40, 100, width: 8)
    reject(bytes, 'image_entry_or_phdr')
  end

  def test_image_virtual_span_and_flags_are_checked
    bytes = PackFixture.valid
    PackFixture.integer(bytes, PackFixture.root_offset(bytes) + 16, 8192, width: 8)
    reject(bytes, 'image_entry_or_phdr')
    bytes = PackFixture.valid
    PackFixture.integer(bytes, PackFixture.root_offset(bytes) + 56 + 32, 7)
    reject(bytes, 'image_segment_range')
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
    reject(bytes, 'manifest_flags')
  end

  def test_system_release_cannot_be_split_by_an_unmarked_file
    bytes = PackFixture.valid(paths: ['a', 'b', 'system/root'])
    PackFixture.integer(bytes, 64 + 7, 1, width: 1)
    reject(bytes, 'release_run')
  end
end
