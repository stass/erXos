# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true
# erx-gate: sanitizers

require 'fileutils'
require 'minitest/autorun'
require_relative '../fixtures/pack_fixture'
require 'tmpdir'
require_relative '../../tools/lib/erx/abi'
require_relative '../../tools/lib/erx/pack_tools'
require_relative '../../tools/lib/erx/pack_wire'
require_relative '../../tools/lib/erx/runner'
require_relative '../fixtures/generated_tree'

# Judges liberx/release_fs.c against a plain model of the design's rules
# (design-files.md, Erlang clients and Resolving a path; design-runtime.md, Files):
# every name list of up to DEPTH names over an alphabet of a small tree's names and
# of names the decoder refuses is added name by name, then walked, looked up and
# listed. Hand cases pin each limit of a name and of a list, and seeded one-line
# mutants must each fail the exploration or their limit. liberx/release.c reads the
# release's run from an archive PackWire wrote.
class ReleaseFsTest < Minitest::Test
  KIND_FILE = 0
  KIND_DIRECTORY = 1
  KIND_MISSING = 2
  KIND_NOT_DIRECTORY = 3
  NAME_MAX = 255
  NAMES_MAX = 256

  # `-` (0x2d) and `0` (0x30) sort around `/` (0x2f), so `d`'s run sits among its neighbours.
  TREE = %w[d-x d/e/i d/g d/h d0 dd/j f].freeze
  ALPHABET = ['', '.', '..', 'a/b', 'd', 'd-x', 'e', 'f', 'g', 'zz'].freeze
  DEPTH = 4
  # The rest of the tree's names, over shorter lists, so every file is reached.
  WIDE_ALPHABET = (ALPHABET + %w[d0 dd h i j]).freeze
  WIDE_DEPTH = 3

  # accepted holds add_name's answer for each name given; the rest is the list's.
  Answer = Data.define(:accepted, :count, :names, :passed, :stop, :kind, :file, :listing)
  CORE = 'liberx/release_fs.c'

  def setup
    @root = File.expand_path('../..', __dir__)
    @directory = Dir.mktmpdir('erx-release-fs-')
    @runner = Erx::Runner.new(owner_root: @directory, log_dir: File.join(@directory, 'logs'))
    @driver = build_driver(File.join(@root, CORE), name: 'driver')
  end

  def teardown = FileUtils.remove_entry(@directory)

  def test_every_short_name_list_agrees_with_the_model
    wrong = exploration_differences(@driver)
    assert_empty wrong.first(5), "#{wrong.size} of the name lists disagree with the model"
  end

  def test_a_name_is_one_to_255_bytes_of_utf8_without_slash_or_nul
    name255 = 'n' * NAME_MAX
    table = { name255 => true, "#{name255}n" => false, '' => false, '.' => false, '..' => false, '...' => true,
              '.a' => true, 'a/b' => false, '/' => false, "a\0b" => false, "\0" => false, "a\xC0\xAFb" => false,
              "\xED\xA0\x80" => false, "\xF4\x90\x80\x80" => false, "\xE2\x82" => false, "\xE2\x82\xAC" => true,
              "\xE0\x80\x80" => false, "\xF0\x80\x80\x80" => false,
              "\xF4\x8F\xBF\xBF" => true }
    table.zip(ask(table.keys.map { |name| [name] })).each do |(name, accepted), answer|
      label = "name #{name.b[0, 24].inspect} of #{name.bytesize} bytes"
      assert_equal [[accepted], accepted ? name.b : ''], [answer.accepted, answer.names.b], label
    end
  end

  def test_a_list_holds_at_most_256_names
    full, over = ask([['n'] * NAMES_MAX, ['n'] * (NAMES_MAX + 2)])
    assert_equal [[true] * NAMES_MAX, NAMES_MAX], [full.accepted, full.count]
    assert_equal [[true] * NAMES_MAX + [false, false], NAMES_MAX], [over.accepted, over.count]
    assert_equal (['n'] * NAMES_MAX).join('/'), over.names
  end

  # The list's bytes keep a NUL's room: 4,095 bytes fit and 4,096 do not.
  def test_a_list_keeps_the_room_of_a_nul
    long = ['n' * NAME_MAX] * 15
    fits, full = ask([[*long, 'n' * 253, 'n'], [*long, 'n' * 254, 'n']])
    assert_equal [4095, true], [fits.names.bytesize, fits.accepted.last]
    assert_equal [4094, false], [full.names.bytesize, full.accepted.last]
  end

  def test_a_refused_name_leaves_the_list_as_it_was
    answer = ask([['d', '..', 'e', 'a/b', '', 'i']]).first
    assert_equal [[true, false, true, false, false, true], 'd/e/i', KIND_FILE], [answer.accepted, answer.names, answer.kind]
  end

  # A fid draw (otp/erts/emulator/nifs/erxos/erx_fid.h) keeps the counter's low 32 bits
  # and skips NOFID, also past a wrap.
  def test_a_fid_is_the_low_32_bits_and_never_nofid
    values = [0, 1, 0xffff_fffe, 0xffff_ffff, 0x1_0000_0000, 0x1_0000_0005, 0x1_ffff_ffff, 0xffff_ffff_ffff_ffff]
    input = File.join(@directory, 'fids')
    File.write(input, values.map { |value| "N #{value}\n" }.join)
    record = @runner.run([@driver, input], name: 'release-fs-fids', deadline: 60)
    assert_equal ['1 0', '1 1', '1 4294967294', '0 0', '1 0', '1 5', '0 0', '0 0'],
                 File.readlines(record.fetch('log'), chomp: true)
  end

  def test_mutants_of_the_core_fail
    mutants = {
      'a binary search off by one' => ['low = middle + 1;', 'low = middle + 2;'],
      'a listing that yields a name twice' => ["erx_release_fs_below(&fs->files[*cursor], file->path, end))\n\t\t(*cursor)++;",
                                              "erx_release_fs_below(&fs->files[*cursor], file->path, end))\n\t\tbreak;"],
      'a file used as a directory answered as missing' => ['return (ERX_RELEASE_FS_NOT_DIRECTORY);',
                                                           'return (ERX_RELEASE_FS_MISSING);'],
      'a decoder that takes ..' => ["(length == 2 && name[0] == '.' && name[1] == '.') ||", ''],
      'a decoder that takes a slash' => ["name[index] == '/'", 'false'],
      'a walk that passes a file' => ['if (kind != ERX_RELEASE_FS_DIRECTORY) {', 'if (kind == ERX_RELEASE_FS_MISSING) {']
    }
    mutants.each do |label, (from, to)|
      driver = build_mutant(from, to, name: label.tr(' .', '_'))
      refute_empty exploration_differences(driver), "#{label} went unnoticed"
    end
  end

  # Each limit's check removed accepts the name its hand case refuses.
  def test_limit_mutants_fail
    long = ['n' * NAME_MAX] * 15
    mutants = {
      'the name length unchecked' => ['length > ERX_NAME_MAX ||', '', ['n' * (NAME_MAX + 1)]],
      'the name count unchecked' => ['names->count == ERX_NS_NAMES_MAX || ', '', ['n'] * (NAMES_MAX + 1)],
      'a NUL taken' => ["if (point == 0)\n\t\t\treturn (false);", '', ["a\0b"]],
      'an overlong form taken' => ['point < minimum ||', 'point < minimum / 0x10000 ||', ["\xE0\x80\x80"]],
      'the room of the NUL unchecked' => ['needed >= sizeof(names->bytes) - names->length',
                                          'needed > sizeof(names->bytes) - names->length', [*long, 'n' * 254, 'n']]
    }
    mutants.each do |label, (from, to, names)|
      driver = build_mutant(from, to, name: label.downcase.tr(' ', '_'))
      assert_equal [true] * names.size, ask([names], driver: driver).first.accepted, "#{label} still refused"
    end
  end

  def test_the_release_is_the_run_under_system
    archive = write_archive
    lines = release_lines(archive)
    assert_equal %w[d/g manifest root], lines.first(3).map { |line| line.split.first }
    assert_equal ['past 1', 'addr 1'], lines.last(2)
    sizes = lines.first(3).map { |line| Integer(line.split[1]) }
    assert_equal [2, 9, 4], sizes
    offsets = lines.first(3).map { |line| Integer(line.split[2]) }
    assert_equal 'g!', File.binread(archive, 2, offsets.first)
    assert_equal 'root', File.binread(archive, 4, offsets.last)
  end

  # A longer name, or more names, than a name list holds is refused at bind.
  def test_a_name_a_name_list_refuses_is_refused_at_bind
    assert_equal ['refused release_name'], bound(["system/#{'z' * 256}"])
    assert_equal ['refused release_name'], bound([(['system'] + ['z'] * 257).join('/')])
    assert(bound(["system/#{'z' * 255}"]).any? { |line| line.start_with?("#{'z' * 255} 1 ") })
    assert_equal 'past 1', bound([(['system'] + ['z'] * 256).join('/')]).fetch(-2)
    assert_equal 'past 1', bound(["other/#{'z' * 256}"]).fetch(-2), 'a name outside the run is not the release'
  end

  def test_a_damaged_archive_is_refused_with_its_check_named
    archive = write_archive
    bytes = File.binread(archive)
    bytes.setbyte(100, bytes.getbyte(100) ^ 1)
    File.binwrite(archive, bytes)
    assert_equal ['refused index_hash'], release_lines(archive)
    File.binwrite(archive, 'not an archive')
    assert_match(/\Arefused /, release_lines(archive).first)
  end

  private

  def compiler = ENV.fetch('ERX_CLANG', 'clang')

  def build_driver(source, name:)
    sanitizers = ENV.fetch('ERX_SANITIZERS', '').split(',').reject(&:empty?)
    flags = sanitizers.empty? ? [] : ["-fsanitize=#{sanitizers.join(',')}", '-fno-omit-frame-pointer']
    output = File.join(@directory, name)
    @runner.run([compiler, '-std=c17', '-D_DARWIN_C_SOURCE', '-D_GNU_SOURCE', '-Wall', '-Wextra', '-Werror', '-pedantic', '-O1', '-g',
                 *flags, *Erx::Generated.include_flags(root: @root),
                 '-I', File.join(@root, 'include'), '-I', File.join(@root, 'otp/erts/emulator/nifs/erxos'), source,
                 File.join(@root, 'test/fixtures/release_fs_driver.c'), '-o', output],
                name: "release-fs-#{name}", deadline: 120)
    output
  end

  def build_mutant(from, to, name:)
    text = File.read(File.join(@root, CORE))
    assert_includes text, from, "the #{name} seed no longer applies"
    mutated = File.join(@directory, "#{name}.c")
    File.write(mutated, text.sub(from) { to })
    build_driver(mutated, name: "mutant_#{name}")
  end

  def write_archive
    tools = Erx::PackTools.build(root: @root, owner_root: @directory, directory: File.join(@directory, 'tools'),
                                 runner: @runner, compiler: compiler)
    codec = Erx::ABI::Codec.new(Erx::ABI::Generator.plan(root: @root).schema)
    flagged = codec.member('entry_flags', 'system')
    file = codec.member('entry_kind', 'file')
    rows = [['aaa/before', 'before', file, 0], ['system/d/g', 'g!', file, flagged],
            ['system/manifest', 'manifest!', file, flagged],
            ['system/root', 'root', codec.member('entry_kind', 'image'), flagged],
            ['zzz/after', 'after', file, 0]].map do |path, bytes, kind, flags|
      snapshot = File.join(@directory, "snapshot-#{path.tr('/', '-')}")
      File.binwrite(snapshot, bytes)
      { 'path' => path, 'kind' => kind, 'flags' => flags, 'size' => bytes.bytesize, 'snapshot' => snapshot }
    end
    archive = File.join(@directory, 'release.pack')
    writer = Erx::PackWire.new(codec: codec, hasher: Erx::PackHasher.new(helper: tools.fetch('hasher'), runner: @runner))
    File.open(archive, 'wb+') do |output|
      writer.write(rows: rows, root_entry: 3, build_kind: 'development', output: output, budget: 1 << 20)
    end
    archive
  end

  def bound(paths)
    archive = File.join(@directory, 'bound.pack')
    File.binwrite(archive, PackFixture.valid(paths: (paths + %w[system/manifest system/root]).sort))
    release_lines(archive)
  end

  def release_lines(archive)
    @release_driver ||= build_release_driver
    record = @runner.run([@release_driver, archive], name: 'release-driver', deadline: 60)
    File.readlines(record.fetch('log'), chomp: true)
  end

  def build_release_driver
    sanitizers = ENV.fetch('ERX_SANITIZERS', '').split(',').reject(&:empty?)
    flags = sanitizers.empty? ? [] : ["-fsanitize=#{sanitizers.join(',')}", '-fno-omit-frame-pointer']
    output = File.join(@directory, 'release-driver')
    sources = %w[liberx/release.c build/gen/liberx/generated/abi_reader.c kernel/core/pack.c liberx/image_plan.c kernel/crypto/blake3/blake3.c
                 kernel/crypto/blake3/blake3_portable.c test/fixtures/release_driver.c]
    @runner.run([compiler, '-std=c17', '-Wall', '-Wextra', '-Werror', '-pedantic', '-O1', '-g', *flags,
                 *Erx::Generated.include_flags(root: @root),
                 '-I', File.join(@root, 'include'), '-I', File.join(@root, 'kernel/crypto'),
                 *sources.map { |source| File.join(@root, source) }, '-o', output],
                name: 'release-driver-build', deadline: 120)
    output
  end

  def hex(bytes) = bytes.empty? ? '-' : bytes.unpack1('H*')
  def unhex(text) = text == '-' ? '' : [text].pack('H*')

  # One run: the tree, then each list built name by name and asked about.
  def ask(lists, driver: @driver)
    commands = TREE.map { |file| "F #{hex(file)}" } +
               lists.flat_map { |names| ['R', *names.map { |name| "A #{hex(name.b)}" }, 'Q'] }
    input = File.join(@directory, 'commands')
    File.write(input, "#{commands.join("\n")}\n")
    record = @runner.run([driver, input], name: 'release-fs-driver', deadline: 300)
    lines = File.readlines(record.fetch('log'), chomp: true).each
    lists.map do |names|
      accepted = names.map { lines.next == '1' }
      parse(accepted, lines.next)
    end
  end

  def parse(accepted, line)
    count, names, passed, stop, kind, file, listing = line.split(' ', 7)
    Answer.new(accepted: accepted, count: Integer(count), names: unhex(names), passed: Integer(passed),
               stop: Integer(stop), kind: Integer(kind), file: Integer(file),
               listing: listing == '-' ? [] : listing.split(','))
  end

  # The design's rules, plainly.
  def model(names)
    accepted = names.map { |name| valid_name?(name) }
    kept = names.zip(accepted).filter_map { |name, valid| name if valid }
    joined = kept.join('/')
    passed = (1..kept.size).take_while { |depth| model_kind(kept.first(depth).join('/')) == KIND_DIRECTORY }.size
    stop = passed == kept.size ? KIND_DIRECTORY : model_kind(kept.first(passed + 1).join('/'))
    kind = model_kind(joined)
    Answer.new(accepted: accepted, count: kept.size, names: joined, passed: passed, stop: stop, kind: kind,
               file: kind == KIND_FILE ? TREE.index(joined) : -1,
               listing: kind == KIND_DIRECTORY ? model_listing(joined) : [])
  end

  def valid_name?(name)
    name.bytesize.between?(1, NAME_MAX) && !%w[. ..].include?(name) && !name.match?(%r{[/\0]}) &&
      name.dup.force_encoding(Encoding::UTF_8).valid_encoding?
  end

  def model_kind(names)
    return KIND_DIRECTORY if names.empty?
    return KIND_FILE if TREE.include?(names)
    return KIND_DIRECTORY if TREE.any? { |file| file.start_with?("#{names}/") }
    return KIND_NOT_DIRECTORY if TREE.any? { |file| names.start_with?("#{file}/") }

    KIND_MISSING
  end

  def model_listing(names)
    prefix = names.empty? ? '' : "#{names}/"
    TREE.select { |file| file.start_with?(prefix) }.map { |file| file.delete_prefix(prefix).split('/').first }.uniq
  end

  def all_lists
    [[ALPHABET, DEPTH], [WIDE_ALPHABET, WIDE_DEPTH]].flat_map do |alphabet, deepest|
      (0..deepest).flat_map { |depth| alphabet.repeated_permutation(depth).to_a }
    end.uniq
  end

  def exploration_differences(driver)
    lists = all_lists
    lists.zip(ask(lists, driver: driver)).filter_map do |names, answer|
      want = model(names)
      "#{names.inspect}: #{answer.to_h} != #{want.to_h}" if answer != want
    end
  end
end
