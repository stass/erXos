# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true
# erx-gate: sanitizers

require 'minitest/autorun'
require 'fileutils'
require 'tmpdir'
require_relative '../fixtures/first_stage_fixture'
require_relative '../fixtures/pack_fixture'
require_relative '../../tools/lib/erx/abi'
require_relative '../../tools/lib/erx/abi_binary'
require_relative '../../tools/lib/erx/boot_file'
require_relative '../../tools/lib/erx/runner'
require_relative '../../tools/fuzz/run_pack'
require_relative '../fixtures/generated_tree'

# The single bootable file: the packer's writer, and erx_boot_locate over what
# it wrote and over each way a locator or a memory map can be wrong.
class BootFileTest < Minitest::Test
  LOAD = 0x4020_0000
  RAM = ['memory', 0x4000_0000, 0x1000_0000].freeze
  TREE = ['tree', 0x4800_0000, 0x1_0000].freeze
  ARCHIVE_OFF = 0x4000
  ARCHIVE_SIZE = 0x3000

  def setup
    @root = File.expand_path('../..', __dir__)
    @directory = Dir.mktmpdir('erx-boot-file-')
    @codec = Erx::ABI::Codec.new(Erx::ABI::Generator.plan(root: @root).schema)
    @runner = Erx::Runner.new(owner_root: @directory, log_dir: File.join(@directory, 'logs'))
    @driver = File.join(@directory, 'boot-locate')
    sanitizers = ENV.fetch('ERX_SANITIZERS', '').split(',').reject(&:empty?)
    raise Erx::Error, 'unsupported boot-file sanitizer' unless (sanitizers - %w[address undefined]).empty?

    flags = sanitizers.empty? ? [] : ["-fsanitize=#{sanitizers.join(',')}", '-fno-omit-frame-pointer']
    @runner.run(['clang', '-std=c17', '-Wall', '-Wextra', '-Werror', '-pedantic', '-O1', '-g', *flags,
                 *Erx::Generated.include_flags(root: @root),
                 '-I', File.join(@root, 'include'), '-I', File.join(@root, 'kernel/crypto'),
                 '-I', File.join(@root, 'tools/host'),
                 File.join(@root, 'kernel/core/pack.c'), File.join(@root, 'kernel/crypto/blake3/blake3.c'),
                 File.join(@root, 'kernel/crypto/blake3/blake3_portable.c'),
                 Erx::Generated.path('liberx/generated/abi_reader.c', root: @root), File.join(@root, 'tools/host/input.c'),
                 File.join(@root, 'test/fixtures/boot_locate_driver.c'), '-o', @driver],
                name: 'compile-boot-locate', deadline: 60)
  end

  def teardown
    FileUtils.remove_entry(@directory) if passed? && File.directory?(@directory)
  end

  # A first stage whose header and locator hold these values, run through
  # the driver with its linked end and the given ranges.
  def locate(ranges, off: ARCHIVE_OFF, size: ARCHIVE_SIZE, declared: ARCHIVE_OFF + ARCHIVE_SIZE, load: LOAD,
             linked_end: FirstStageFixture::LINKED_END, locator: nil)
    stage = FirstStageFixture.bytes
    stage[16, 8] = [declared].pack('Q<')
    stage[FirstStageFixture::LOCATOR, 32] = locator || FirstStageFixture.locator(off: off, size: size)
    path = File.join(@directory, 'stage')
    File.binwrite(path, stage)
    arguments = [path, load.to_s, linked_end.to_s, *ranges.flatten.map(&:to_s)]
    record = @runner.run([@driver, *arguments], name: 'boot-locate', deadline: 30)
    File.read(record.fetch('log')).chomp
  end

  def single_file
    archive = File.join(@directory, 'archive')
    File.binwrite(archive, PackFixture.valid)
    stage = File.join(@directory, 'first-stage')
    File.binwrite(stage, FirstStageFixture.bytes)
    output = File.join(@directory, 'single')
    Erx::BootFile.write(codec: @codec, first_stage: stage, archive: archive, output: output, output_root: @directory)
    [File.binread(output), File.binread(archive)]
  end

  def test_single_file_changes_only_the_locator_and_the_declared_size
    single, archive = single_file
    stage = FirstStageFixture.bytes
    assert_equal archive, single.byteslice(ARCHIVE_OFF, archive.bytesize)
    assert_equal ARCHIVE_OFF + archive.bytesize, single.bytesize
    assert_equal ARCHIVE_OFF + archive.bytesize, single.byteslice(16, 8).unpack1('Q<')
    assert_equal FirstStageFixture.locator(off: ARCHIVE_OFF, size: archive.bytesize), single.byteslice(64, 32)
    assert_equal stage.byteslice(0, 16), single.byteslice(0, 16)
    assert_equal stage.byteslice(24, 40), single.byteslice(24, 40)
    assert_equal stage.byteslice(96..), single.byteslice(96, stage.bytesize - 96)
    assert_equal "\0".b * (ARCHIVE_OFF - stage.bytesize), single.byteslice(stage.bytesize, ARCHIVE_OFF - stage.bytesize)
  end

  def test_equal_inputs_give_equal_single_files
    assert_equal single_file.first, single_file.first
  end

  def test_the_located_archive_is_the_one_the_packer_wrote
    single, archive = single_file
    declared = single.byteslice(16, 8).unpack1('Q<')
    expected = "ok #{(LOAD + ARCHIVE_OFF).to_s(16)} #{archive.bytesize.to_s(16)}"
    assert_equal expected, locate([RAM, TREE], size: archive.bytesize, declared: declared)
  end

  def test_writer_refuses_what_is_not_a_first_stage_as_built
    packed = FirstStageFixture.bytes
    packed[FirstStageFixture::LOCATOR, 32] = FirstStageFixture.locator(off: 0x4000, size: 0x1000)
    wrong_magic = FirstStageFixture.bytes
    wrong_magic[56, 4] = 'XXXX'.b
    wrong_locator = FirstStageFixture.bytes
    wrong_locator[FirstStageFixture::LOCATOR] = 'X'
    nonzero = FirstStageFixture.bytes
    nonzero[FirstStageFixture::LOCATOR + 12, 4] = [1].pack('V')
    undeclared = FirstStageFixture.bytes(linked_end: FirstStageFixture::SIZE - 1)
    enormous = FirstStageFixture.bytes(linked_end: 1 << 63)
    [packed, wrong_magic, wrong_locator, nonzero, undeclared, enormous, 'short'.b].each do |stage|
      assert_raises(Erx::Error) { Erx::BootFile.head(codec: @codec, first_stage: stage, archive_size: 4096) }
    end
    [0, 1, 4095].each do |size|
      assert_raises(Erx::Error) do
        Erx::BootFile.head(codec: @codec, first_stage: FirstStageFixture.bytes, archive_size: size)
      end
    end
  end

  def test_a_failed_write_keeps_the_earlier_output
    output = File.join(@directory, 'kept')
    File.binwrite(output, 'earlier')
    stage = File.join(@directory, 'bad-stage')
    File.binwrite(stage, 'short')
    archive = File.join(@directory, 'archive')
    File.binwrite(archive, PackFixture.valid)
    not_an_archive = File.join(@directory, 'one-page')
    File.binwrite(not_an_archive, "\0".b * 4096)
    good_stage = File.join(@directory, 'good-stage')
    File.binwrite(good_stage, FirstStageFixture.bytes)
    [[stage, archive], [good_stage, not_an_archive]].each do |first_stage, input|
      assert_raises(Erx::Error) do
        Erx::BootFile.write(codec: @codec, first_stage: first_stage, archive: input, output: output, output_root: @directory)
      end
    end
    assert_equal 'earlier', File.binread(output)
    assert_empty Dir.children(@directory).select { |name| name.start_with?('.erx-boot-') }
  end

  def test_a_locator_with_a_wrong_field_stops_the_boot
    [FirstStageFixture.locator(magic: "ERXBOOX\0".b), FirstStageFixture.locator(version: 2),
     FirstStageFixture.locator(zero: 1), FirstStageFixture.locator(off: 0x4000),
     FirstStageFixture.locator(size: 0x1000)].each do |locator|
      assert_equal 'error locator', locate([RAM, TREE], locator: locator)
    end
  end

  def test_exactly_one_boot_image
    initrd = ['initrd', 0x4400_0000, 0x3000]
    assert_equal 'error no_boot_image', locate([RAM, TREE], off: 0, size: 0)
    assert_equal 'ok 44000000 3000', locate([RAM, TREE, initrd], off: 0, size: 0)
    assert_equal 'error two_boot_images', locate([RAM, TREE, initrd])
  end

  def test_the_archive_must_follow_the_first_stage_inside_the_declared_size
    # Linked end 0x3080: the first page boundary at or after it is 0x4000.
    assert_equal 'ok 40204000 3000', locate([RAM, TREE], off: 0x4000)
    assert_equal 'ok 40204000 3000', locate([RAM, TREE], off: 0x4000, linked_end: 0x4000)
    assert_equal 'error locator_range', locate([RAM, TREE], off: 0x4000, linked_end: 0x4001)
    assert_equal 'error locator_range', locate([RAM, TREE], off: 0x3000), 'inside zero-initialised data'
    assert_equal 'error locator_range', locate([RAM, TREE], off: 0x4001), 'not on a page'
    assert_equal 'error locator_range', locate([RAM, TREE], declared: 0x6fff), 'past the declared size'
    assert_equal 'error locator_range', locate([RAM, TREE], off: 0xffff_ffff_ffff_f000, size: 0x1000), 'offset plus size wraps'
    # With no load to wrap as well, only the first overflow check names this.
    assert_equal 'error locator_range', locate([RAM, TREE], off: 0xffff_ffff_ffff_f000, size: 0x2000, load: 0)
    assert_equal 'error locator_range', locate([RAM, TREE], load: 0xffff_ffff_ffff_e000, declared: 1 << 63), 'load plus offset wraps'
  end

  def test_the_archive_must_lie_in_one_memory_range_clear_of_everything
    assert_equal 'error archive_memory', locate([TREE])
    assert_equal 'error archive_memory', locate([['memory', LOAD, ARCHIVE_OFF + 0x2fff], TREE]), 'one byte short'
    assert_equal 'ok 40204000 3000', locate([['memory', LOAD, ARCHIVE_OFF + ARCHIVE_SIZE], TREE])
    assert_equal 'error archive_memory',
                 locate([['memory', LOAD, ARCHIVE_OFF + 0x1000], ['memory', LOAD + ARCHIVE_OFF + 0x1000, 0x2000], TREE]),
                 'spanning two ranges'
    assert_equal 'error archive_overlap', locate([RAM, ['tree', LOAD + ARCHIVE_OFF + 0x2fff, 1]])
    assert_equal 'ok 40204000 3000', locate([RAM, ['tree', LOAD + ARCHIVE_OFF + 0x3000, 1]])
    assert_equal 'error archive_overlap', locate([RAM, TREE, ['reserved', LOAD + ARCHIVE_OFF, 1]])
    assert_equal 'error archive_overlap', locate([RAM, ['tree', 0xffff_ffff_ffff_f000, 0x2000]]), 'a range that wraps'
  end

  # A seeded off-by-one in the declared-size bound: the target must abort from
  # the seeds it runs with. They hold an input one past the bound, so this
  # shows that its statement of the locator's rules is live, not that
  # mutation reaches the bug.
  def test_the_fuzz_target_catches_a_seeded_off_by_one
    seeded = File.read(File.join(@root, 'kernel/core/pack.c'))
                 .sub('end > inputs->declared_size', 'end > inputs->declared_size + 1')
    refute_equal File.read(File.join(@root, 'kernel/core/pack.c')), seeded
    File.write(File.join(@directory, 'seeded.c'), seeded)
    corpus = File.join(@directory, 'corpus')
    Dir.mkdir(corpus)
    boot = Erx::PackFuzz.targets.find { |target| target.kind == 'boot' }
    boot.seeds.each { |name, bytes| File.binwrite(File.join(corpus, name), bytes) }
    program = File.join(@directory, 'seeded-fuzz')
    @runner.run([ENV.fetch('ERX_CLANG', 'clang'), '-std=c17', '-O1', '-g', '-fsanitize=fuzzer,address,undefined',
                 *Erx::Generated.include_flags(root: @root),
                 '-I', File.join(@root, 'include'), '-I', File.join(@root, 'kernel/crypto'),
                 File.join(@directory, 'seeded.c'), File.join(@root, 'kernel/crypto/blake3/blake3.c'),
                 File.join(@root, 'kernel/crypto/blake3/blake3_portable.c'),
                 Erx::Generated.path('liberx/generated/abi_reader.c', root: @root),
                 File.join(@root, 'tools/fuzz/boot_fuzz.c'), '-o', program], name: 'compile-seeded-fuzz', deadline: 90)
    error = assert_raises(Erx::CommandError) do
      @runner.run([program, '-runs=20000', '-seed=1', '-max_len=32768', '-timeout=5',
                   "-artifact_prefix=#{@directory}/", corpus], name: 'seeded-fuzz', deadline: 120)
    end
    assert_match(/deadly signal/, File.read(error.result.fetch('log')))
  end

  def test_an_initrd_is_held_to_the_same_placement
    off = { off: 0, size: 0 }
    assert_equal 'error archive_extent', locate([RAM, TREE, ['initrd', 0x4400_0001, 0x3000]], **off), 'not on a page'
    assert_equal 'error archive_extent', locate([RAM, TREE, ['initrd', 0x4400_0000, 0]], **off), 'empty'
    assert_equal 'error archive_memory', locate([RAM, TREE, ['initrd', 0x8000_0000, 0x1000]], **off)
    assert_equal 'error archive_overlap', locate([RAM, TREE, ['initrd', LOAD + 0x3000, 0x1000]], **off), 'over the first stage'
    assert_equal 'ok 40204000 1000', locate([RAM, TREE, ['initrd', LOAD + 0x4000, 0x1000]], **off)
  end
end
