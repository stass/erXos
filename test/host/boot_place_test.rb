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
require_relative '../../tools/lib/erx/boot_file'
require_relative '../../tools/lib/erx/runner'

# erx_boot_load_plan and the handoff record, from literal bytes. kernel/core/boot_place.c
# liberx/elf_plan.c kernel/core/boot_handoff.c
class BootPlaceTest < Minitest::Test
  LOAD = 0x4020_0000
  MEMORY = 0x4000_0000
  MEMORY_SIZE = 0x2000_0000
  MIB2 = 0x20_0000
  PT_LOAD = 1
  PT_DYNAMIC = 2
  PT_KIP = 0x10
  PT_KOPTIONS = 0x11
  Header = Struct.new(:type, :offset, :address, :file_size, :memory_size, :alignment)

  def setup
    @root = File.expand_path('../..', __dir__)
    @directory = Dir.mktmpdir('boot-place', File.join(@root, 'build').tap { |path| FileUtils.mkdir_p(path) })
    @runner = Erx::Runner.new(owner_root: @directory, log_dir: File.join(@directory, 'logs'))
    @codec = Erx::ABI::Codec.new(Erx::ABI::Generator.plan(root: @root).schema)
    @driver = File.join(@directory, 'driver')
    sanitizers = ENV.fetch('ERX_SANITIZERS', '').split(',').reject(&:empty?)
    flags = sanitizers.empty? ? [] : ["-fsanitize=#{sanitizers.join(',')}", '-fno-omit-frame-pointer', '-fno-sanitize-recover=all']
    sources = %w[kernel/core/boot_place.c kernel/core/boot_handoff.c kernel/core/pack.c liberx/elf_plan.c
                 liberx/generated/abi_reader.c kernel/crypto/blake3/blake3.c kernel/crypto/blake3/blake3_portable.c
                 test/fixtures/boot_place_driver.c].map { |source| File.join(@root, source) }
    @runner.run(['clang', '-std=c17', '-Wall', '-Wextra', '-Werror', '-pedantic', '-O1', '-g', *flags,
                 '-I', File.join(@root, 'include'), '-I', File.join(@root, 'kernel/crypto'), *sources, '-o', @driver],
                name: 'compile-boot-place', deadline: 60)
  end

  def teardown
    FileUtils.remove_entry(@directory) if passed? && File.directory?(@directory)
  end

  # An ELF from literal offsets: a 64-byte header, 56-byte program headers, then
  # the bytes the headers describe.
  def elf(entry:, headers:, size: 0x3000)
    bytes = "\xAB".b * size
    bytes[0, 64] = ["\x7FELF\x02\x01\x01".b.ljust(16, "\0"), 2, 183, 1, entry, 64, 0, 0, 64, 56, headers.size, 64, 0, 0]
                   .pack('a16vvVQ<Q<Q<VvvvvvV').byteslice(0, 64)
    headers.each_with_index do |header, index|
      bytes[64 + index * 56, 56] = [header.type, 7, header.offset, header.address, header.address,
                                    header.file_size, header.memory_size, header.alignment].pack('VVQ<6')
    end
    bytes
  end

  def kernel(entry: 0x1000, headers: nil)
    elf(entry: entry, headers: headers || [
          Header.new(PT_LOAD, 0x1000, 0x1000, 0x2000, 0x3000, 0x1000),
          Header.new(PT_DYNAMIC, 0x1000, 0x1000, 0x10, 0x10, 8),
          Header.new(PT_KIP, 0x1000, 0x1000, 0x1000, 0x1000, 8),
          Header.new(PT_KOPTIONS, 0x2000, 0x2000, 0x100, 0x100, 8)
        ])
  end

  def sigma0(size: 0x3000)
    elf(entry: 0x1800, headers: [Header.new(PT_LOAD, 0x1000, 0x1000, 0x1000, 0x2000, 0x10000),
                                 Header.new(PT_DYNAMIC, 0x1000, 0x1000, 0x10, 0x10, 8)], size: size)
  end

  def fixed_root(address: 0x4400_0000)
    elf(entry: address, headers: [Header.new(PT_LOAD, 0x1000, address, 0x1000, 0x2000, 0x1000)])
  end

  def archive(files)
    names = (files.keys + ['system/root']).sort
    PackFixture.valid(paths: names, files: files.transform_keys(&:b))
  end

  def standard = { 'boot/kernel' => kernel, 'boot/sigma0' => sigma0 }

  # The single file for an archive, from literal offsets: the first stage's size
  # rounded up to a page, then the archive.
  def plan(archive_bytes, memory_size: MEMORY_SIZE, reserved: nil)
    single = FirstStageFixture.bytes
    single << "\0".b * (0x4000 - single.bytesize)
    single[16, 8] = [0x4000 + archive_bytes.bytesize].pack('Q<')
    single[FirstStageFixture::LOCATOR, 32] = FirstStageFixture.locator(off: 0x4000, size: archive_bytes.bytesize)
    single << archive_bytes
    path = File.join(@directory, 'single')
    File.binwrite(path, single)
    record = @runner.run([@driver, 'plan', path, LOAD.to_s, FirstStageFixture::LINKED_END.to_s, MEMORY.to_s, memory_size.to_s, *reserved&.map(&:to_s)],
                         name: 'boot-place', deadline: 30)
    File.binread(record.fetch('log'))
  end

  def refused(*arguments, **options) = plan(*arguments, **options).lines.first.strip

  def test_a_good_archive_places_the_kernel_behind_it_on_the_unit
    output = plan(archive(standard))
    archive_line = output[/^archive (\h+) (\h+)$/]
    assert archive_line, output
    archive_start = $1.to_i(16)
    archive_size = $2.to_i(16)
    assert_equal LOAD + 0x4000, archive_start
    floor = (archive_start + archive_size + MIB2 - 1) / MIB2 * MIB2
    # The kernel's link origin is 0 at its alignment, so its entry moves with it.
    assert_match(/^kernel #{(floor + 0x1000).to_s(16)} 3000 #{(floor + 0x1000).to_s(16)}$/, output)
    assert_match(/^kip #{(floor + 0x1000).to_s(16)} 1000$/, output)
    assert_match(/^koptions #{(floor + 0x2000).to_s(16)} 100$/, output)
    # sigma0 is behind the kernel, at its own alignment.
    assert_match(/^sigma0 \h+ 2000 \h+$/, output)
    refute_match(/^root /, output)
    # Each copy names the file's bytes at their entry's offset.
    assert_equal 2, output.scan(/^copy /).size
    # The record starts with the version, the flags, the build id and the hash.
    record = output.b[/copy [^\n]*\n(?!copy)(.*)\n\z/mn, 1]
    assert_equal [3, 1], record.unpack('VV')
  end

  def test_an_image_without_a_dynamic_section_runs_where_it_is_linked
    output = plan(archive(standard.merge('boot/stopgap-root' => fixed_root)))
    assert_match(/^root 44000000 2000 44000000$/, output)
    assert_equal 3, output.scan(/^copy /).size
  end

  def test_a_reservation_moves_the_kernel_to_the_next_unit
    free = plan(archive(standard))[/^kernel (\h+) /, 1].to_i(16)
    moved = plan(archive(standard), reserved: [free, 0x1000])[/^kernel (\h+) /, 1].to_i(16)
    assert_equal free + MIB2, moved
  end

  def test_a_fixed_image_on_a_reservation_is_refused
    assert_equal 'refused boot/stopgap-root place_overlap',
                 refused(archive(standard.merge('boot/stopgap-root' => fixed_root)), reserved: [0x4400_0000, 0x1000])
  end

  def test_a_kernel_that_cannot_move_is_refused
    headers = [Header.new(PT_LOAD, 0x1000, 0x4400_1000, 0x2000, 0x3000, 0x1000),
               Header.new(PT_KIP, 0x1000, 0x4400_1000, 0x1000, 0x1000, 8),
               Header.new(PT_KOPTIONS, 0x2000, 0x4400_2000, 0x100, 0x100, 8)]
    assert_equal 'refused boot/kernel kernel_not_relocatable',
                 refused(archive(standard.merge('boot/kernel' => kernel(entry: 0x4400_1000, headers: headers))))
  end

  def test_a_view_or_entry_off_its_alignment_is_refused
    load = Header.new(PT_LOAD, 0x1000, 0x1000, 0x2000, 0x3000, 0x1000)
    dynamic = Header.new(PT_DYNAMIC, 0x1000, 0x1000, 0x10, 0x10, 8)
    kip = Header.new(PT_KIP, 0x1000, 0x1000, 0x1000, 0x1000, 8)
    koptions = Header.new(PT_KOPTIONS, 0x2000, 0x2000, 0x100, 0x100, 8)
    assert_equal 'refused boot/kernel view_alignment',
                 refused(archive(standard.merge('boot/kernel' => kernel(headers: [load, dynamic, kip, Header.new(PT_KOPTIONS, 0x2004, 0x2004, 0x100, 0x100, 8)]))))
    assert_equal 'refused boot/kernel view_alignment',
                 refused(archive(standard.merge('boot/kernel' => kernel(headers: [load, dynamic, Header.new(PT_KIP, 0x1800, 0x1800, 0x1000, 0x1000, 8), koptions]))))
    assert_equal 'refused boot/kernel entry_outside', refused(archive(standard.merge('boot/kernel' => kernel(entry: 0x1002))))
  end

  def test_a_role_that_is_missing_is_named
    assert_equal 'refused boot/kernel entry_missing', refused(archive('boot/sigma0' => sigma0))
    assert_equal 'refused boot/sigma0 entry_missing', refused(archive('boot/kernel' => kernel))
  end

  def test_a_kernel_entry_that_is_no_file_is_refused
    bytes = archive(standard)
    index = field_index(bytes, 'boot/kernel')
    bytes[PackFixture.entry_offset(index) + 6] = "\x02".b
    assert_equal 'refused boot/kernel entry_not_file', refused(PackFixture.rehash(bytes))
  end

  def test_a_flipped_kernel_byte_stops_at_the_file_check_before_the_elf_reader
    bytes = archive(standard)
    offset = PackFixture.field(bytes, PackFixture.entry_offset(field_index(bytes, 'boot/kernel')) + 8, 8)
    # Past the ELF header, or the magic: the reader would refuse this byte too,
    # so naming the file check shows it ran first.
    bytes[offset] = (bytes.getbyte(offset) ^ 1).chr.b
    assert_equal 'refused boot/kernel file_hash', refused(bytes)
  end

  def test_nonzero_padding_with_the_hash_recomputed_is_refused
    # A file short of its page, so its run has padding to damage.
    bytes = archive(standard.merge('boot/sigma0' => sigma0(size: 0x2f00)))
    entry = PackFixture.entry_offset(field_index(bytes, 'boot/sigma0'))
    end_of_data = PackFixture.field(bytes, entry + 8, 8) + PackFixture.field(bytes, entry + 16, 8)
    bytes[end_of_data] = "\x01".b
    assert_equal 'refused boot/sigma0 padding', refused(PackFixture.rehash(bytes))
  end

  def test_each_elf_check_stops_with_its_reason
    load = Header.new(PT_LOAD, 0x1000, 0x1000, 0x2000, 0x3000, 0x1000)
    kip = Header.new(PT_KIP, 0x1000, 0x1000, 0x1000, 0x1000, 8)
    koptions = Header.new(PT_KOPTIONS, 0x2000, 0x2000, 0x100, 0x100, 8)
    {
      'view_missing' => [load, kip],
      'view_duplicate' => [load, kip, kip, koptions],
      'view_size' => [load, Header.new(PT_KIP, 0x1000, 0x1000, 0xfff, 0xfff, 8), koptions],
      'view_outside' => [load, Header.new(PT_KIP, 0x1000, 0x10000, 0x1000, 0x1000, 8), koptions],
      'view_offset' => [load, Header.new(PT_KIP, 0x1800, 0x1000, 0x1000, 0x1000, 8), koptions],
      'load_range' => [Header.new(PT_LOAD, 0x1000, 0x1000, 0x4000, 0x3000, 0x1000), kip, koptions],
      'load_order' => [load, Header.new(PT_LOAD, 0x1000, 0x2000, 0x10, 0x10, 0x1000), kip, koptions],
      'load_alignment' => [Header.new(PT_LOAD, 0x1000, 0x1000, 0x2000, 0x3000, 3), kip, koptions],
      'no_load' => [kip, koptions]
    }.each do |reason, headers|
      assert_equal "refused boot/kernel #{reason}", refused(archive(standard.merge('boot/kernel' => kernel(headers: headers)))), reason
    end
    assert_equal 'refused boot/kernel entry_outside', refused(archive(standard.merge('boot/kernel' => kernel(entry: 0x9000))))
    assert_equal 'refused boot/kernel elf_header', refused(archive(standard.merge('boot/kernel' => 'not an elf'.b)))
  end

  def test_placement_refusals
    assert_equal 'refused boot/kernel place_no_room', refused(archive(standard), memory_size: 0x0040_0000)
    # On the archive, then outside memory.
    assert_equal 'refused boot/stopgap-root place_overlap',
                 refused(archive(standard.merge('boot/stopgap-root' => fixed_root(address: LOAD))))
    assert_equal 'refused boot/stopgap-root place_outside_memory',
                 refused(archive(standard.merge('boot/stopgap-root' => fixed_root(address: 0x1000_0000))))
  end

  def test_the_validator_runs_first
    bytes = archive(standard)
    bytes[PackFixture::HEADER + 6] = "\x7F".b
    assert_equal 'refused - index_hash', refused(bytes)
  end

  def handoff(bytes)
    path = File.join(@directory, 'record')
    File.binwrite(path, bytes)
    File.binread(@runner.run([@driver, 'handoff', path], name: 'handoff', deadline: 30).fetch('log')).strip
  end

  # stdout_path's length sits after the 2048 bytes of bootargs, and its bytes after that.
  def record(version: 3, flags: 1, start: 0x4020_4000, size: 0x8000, args: 'erx.a=1', stdout: '/pl011@9000000', stdout_length: stdout.bytesize)
    bytes = [version, flags].pack('VV') + ("\x11".b * 8) + ("\x22".b * 32) + [start, size, 0, 0, 0, args.bytesize].pack('Q<4VV') + args.b
    bytes = bytes.ljust(2136, "\0".b) + [stdout_length].pack('V') + stdout.b
    bytes.ljust(@codec.layout_size('erx_boot_handoff'), "\0".b)
  end

  def test_the_kernel_accepts_a_good_record_and_says_what_it_holds
    assert_equal 'flags 1 development 1 image 40204000 8000 bootargs erx.a=1 stdout /pl011@9000000 covered 1 0', handoff(record)
    assert_match(/development 0 /, handoff(record(flags: 2)))
  end

  def test_the_kernel_refuses_a_record_bootstrap_did_not_write
    assert_equal 'refused version', handoff("\0".b * @codec.layout_size('erx_boot_handoff'))
    assert_equal 'refused version', handoff(record(version: 2))
    assert_equal 'refused flags', handoff(record(flags: 4))
    assert_equal 'refused image_range', handoff(record(start: 0x4020_4001))
    assert_equal 'refused image_range', handoff(record(size: 0))
    assert_equal 'refused image_range', handoff(record(size: 0x8001))
    assert_equal 'refused image_range', handoff(record(start: 0xffff_ffff_ffff_f000, size: 0x2000))
    long = record
    long[84, 4] = [2049].pack('V')
    assert_equal 'refused bootargs_length', handoff(long)
    assert_equal 'refused record_extent', handoff(record.byteslice(0, 100))
  end

  # The path bootstrap resolved from /chosen/stdout-path reaches the root as the node's
  # full path: empty when the tree names none, and otherwise only the characters a node
  # path has, so the root's refusal can print it as it is.
  def test_the_stdout_path_is_a_node_path_or_nothing
    assert_match(/ stdout  covered/, handoff(record(stdout: '')))
    assert_match(%r{ stdout /soc/serial@1,0x9000000_a\+b-c covered}, handoff(record(stdout: '/soc/serial@1,0x9000000_a+b-c')))
    assert_match(/ stdout \/ covered/, handoff(record(stdout: '/')))
    assert_match(/ stdout \/a{255} covered/, handoff(record(stdout: "/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa")))
    assert_equal 'refused stdout_path_length', handoff(record(stdout: '', stdout_length: 257))
    assert_equal 'refused stdout_path', handoff(record(stdout: 'serial0'))
    assert_equal 'refused stdout_path', handoff(record(stdout: '/pl011@9000000:115200'))
    assert_equal 'refused stdout_path', handoff(record(stdout: "/pl011\e[2J"))
    assert_equal 'refused stdout_path', handoff(record(stdout: "/pl011\0"))
  end

  def test_a_command_line_is_cut_at_the_last_whole_word
    assert_equal 5, args(5, 'hello')
    assert_equal 5, args(8, 'hello world')
    assert_equal 5, args(5, 'hello world')
    assert_equal 0, args(4, 'hello world')
  end

  def args(limit, text)
    File.binread(@runner.run([@driver, 'args', limit.to_s, text], name: 'args', deadline: 30).fetch('log')).to_i
  end

  private

  def field_index(bytes, path)
    count = PackFixture.field(bytes, 24, 4)
    strings = PackFixture.field(bytes, 40, 8)
    (0...count).find do |index|
      entry = PackFixture.entry_offset(index)
      bytes.byteslice(strings + PackFixture.field(bytes, entry, 4), PackFixture.field(bytes, entry + 4, 2)) == path.b
    end
  end
end
