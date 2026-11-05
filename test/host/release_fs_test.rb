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

# Judges liberx/ns.c and liberx/release_fs.c against a plain model of the design's
# rules (design-files.md, Resolving a path; design-runtime.md, Files): every path of
# up to DEPTH names over an alphabet of a small tree's names, `.`, `..` and the empty
# name, relative and absolute, from each working directory. Hand cases pin each limit
# and a narrowed namespace, and seeded one-line mutants must each fail the exploration.
# liberx/release.c reads the release's run from an archive PackWire wrote.
class ReleaseFsTest < Minitest::Test
  NS_OK = 0
  NS_EINVAL = 1
  NS_ENAMETOOLONG = 2
  NS_ENOENT = 3
  NS_EEXIST = 4
  NS_EBUSY = 5
  NS_ELIMIT = 6
  NS_EXDEV = 7
  NS_SERVER = 2
  RIGHTS_RO = 0
  RIGHTS_RW = 1
  RIGHTS_RX = 2
  MOUNTS_MAX = 64
  KIND_FILE = 0
  KIND_DIRECTORY = 1
  KIND_MISSING = 2
  KIND_NOT_DIRECTORY = 3

  # `-` (0x2d) and `0` (0x30) sort around `/` (0x2f), so `d`'s run sits among its neighbours.
  TREE = %w[d-x d/e/i d/g d/h d0 dd/j f].freeze
  ALPHABET = ['', '.', '..', 'd', 'd-x', 'e', 'f', 'g', 'zz'].freeze
  DEPTH = 4
  # The rest of the tree's names, over shorter paths, so every file is reached.
  WIDE_ALPHABET = (ALPHABET + %w[d0 dd h i j]).freeze
  WIDE_DEPTH = 3
  WORKING_DIRECTORIES = %w[/ /d /d/e].freeze

  Answer = Data.define(:status, :mount, :nnames, :names, :path, :kind, :file, :listing)
  Entry = Data.define(:point, :kind, :server, :tree, :root, :rights)
  CORE = %w[liberx/ns.c liberx/release_fs.c].freeze

  def setup
    @root = File.expand_path('../..', __dir__)
    @directory = Dir.mktmpdir('erx-release-fs-')
    @runner = Erx::Runner.new(owner_root: @directory, log_dir: File.join(@directory, 'logs'))
    @driver = build_driver(CORE.map { |source| File.join(@root, source) }, name: 'driver')
  end

  def teardown = FileUtils.remove_entry(@directory)

  def test_every_short_path_agrees_with_the_model
    wrong = exploration_differences(@driver)
    assert_empty wrong.first(5), "#{wrong.size} of the paths disagree with the model"
  end

  def test_the_limits_of_a_path
    name255 = 'n' * 255
    table = { name255 => NS_OK, "#{name255}n" => NS_ENAMETOOLONG,
              (['n'] * 256).join('/') => NS_OK, (['n'] * 257).join('/') => NS_ENAMETOOLONG,
              "#{'n/' * 257}../" => NS_ENAMETOOLONG,
              '' => NS_ENOENT, "a\0b" => NS_EINVAL, "a\xC0\xAFb" => NS_EINVAL, "\xED\xA0\x80" => NS_EINVAL,
              "\xF4\x90\x80\x80" => NS_EINVAL, "\xE2\x82" => NS_EINVAL, "\xE2\x82\xAC" => NS_OK }
    table.each do |path, status|
      assert_equal status, ask([path]).first.status, "path #{path.b[0, 24].inspect} of #{path.bytesize} bytes"
    end
  end

  def test_the_whole_path_is_bounded_with_its_nul
    # /nnn... of 4,095 bytes fits a working directory; one more does not, and over 4,096 is refused first.
    long = ->(total) { ("/#{'n' * 200}" * ((total / 201) + 1)).byteslice(0, total) }
    assert_equal NS_OK, ask([long.call(4095)]).first.status
    assert_equal NS_ENAMETOOLONG, ask([long.call(4096)]).first.status
    assert_equal NS_ENAMETOOLONG, ask([long.call(4100)]).first.status
    # Relative, the join to the working directory counts too.
    assert_equal NS_OK, ask([long.call(3995).delete_prefix('/')], cwd: "/#{'c' * 98}").first.status
    assert_equal NS_ENAMETOOLONG, ask([long.call(4095).delete_prefix('/')], cwd: "/#{'c' * 98}").first.status
    # A mount's root counts too: this fits as a path and not under /under.
    mounts = [['/a', '/under']]
    assert_equal NS_ENAMETOOLONG, ask(["/a#{long.call(4091)}"], mounts: mounts).first.status
    assert_equal NS_OK, ask(["/a#{long.call(4080)}"], mounts: mounts).first.status
  end

  def test_a_narrowed_namespace_reaches_only_its_mounts
    mounts = [['/data', '/'], ['/data/logs', '/under/here'], ['/proc', '/']]
    table = {
      '/' => [nil, ''], '/data' => [0, ''], '/data/x' => [0, 'x'], '/data/logs' => [1, 'under/here'],
      '/data/logs/a/b' => [1, 'under/here/a/b'], '/proc/1' => [2, '1'], '/x/../proc' => [2, ''],
      '/data/logs/..' => [0, '']
    }
    table.each do |path, (mount, names)|
      answer = ask([path], mounts: mounts).first
      assert_equal [NS_OK, mount, names], [answer.status, answer.mount, answer.names], path
    end
    %w[/database /etc/passwd /datax /data2/logs].each do |path|
      assert_equal NS_ENOENT, ask([path], mounts: mounts).first.status, path
    end
    # Above a deeper mount only: /a is a directory above /a/b/c, and /a/x is nothing.
    deep = [['/a/b/c', '/']]
    assert_nil ask(['/a'], mounts: deep).first.mount
    assert_equal NS_OK, ask(['/a/b'], mounts: deep).first.status
    assert_equal NS_ENOENT, ask(['/a/x'], mounts: deep).first.status
  end

  # A server mount is an entry of its own: the paths below its point reach it, with
  # its pid, tree and rights; a refused mount leaves the table as it was.
  def test_a_server_mount_takes_the_paths_below_its_point
    lines = edit([mount('/tmp', 7, 'tmp', RIGHTS_RW), 'L', query('/tmp/a/b'), query('/tmpx'), query('tmp')])
    assert_equal '0', lines[0]
    assert_equal [Entry.new(point: '/', kind: 0, server: 0, tree: '', root: '/', rights: RIGHTS_RO),
                  Entry.new(point: '/tmp', kind: NS_SERVER, server: 7, tree: 'tmp', root: '/', rights: RIGHTS_RW)],
                 entries(lines)
    answers = lines.reject { |line| line.start_with?('E ') }.drop(1).map { |line| parse(line) }
    assert_equal [[1, 'a/b'], [0, 'tmpx'], [1, '']], answers.map { |answer| [answer.mount, answer.names] }
  end

  def test_a_mount_is_refused_whole
    long_tree = 'n' * 256
    cases = {
      mount('/', 7, 'tmp', RIGHTS_RW) => NS_EEXIST, mount('/tmp/', 7, 'tmp', RIGHTS_RW) => NS_EEXIST,
      mount('/x', 0, 'tmp', RIGHTS_RW) => NS_EINVAL, mount('/x', 7, '', RIGHTS_RW) => NS_EINVAL,
      mount('/x', 7, 'a/b', RIGHTS_RW) => NS_EINVAL, mount('/x', 7, '.', RIGHTS_RW) => NS_EINVAL,
      mount('/x', 7, '..', RIGHTS_RW) => NS_EINVAL, mount('/x', 7, "a\0b", RIGHTS_RW) => NS_EINVAL,
      mount('/x', 7, "\xff", RIGHTS_RW) => NS_EINVAL, mount('/x', 7, long_tree, RIGHTS_RW) => NS_EINVAL,
      mount('/x', 7, 'tmp', 3) => NS_EINVAL, mount("/x\0", 7, 'tmp', RIGHTS_RW) => NS_EINVAL,
      mount('', 7, 'tmp', RIGHTS_RW) => NS_ENOENT, mount("/#{long_tree}", 7, 'tmp', RIGHTS_RW) => NS_ENAMETOOLONG
    }
    lines = edit([mount('/tmp', 7, 'tmp', RIGHTS_RW), *cases.keys, 'L'])
    assert_equal ['0', *cases.values.map(&:to_s)], lines.first(cases.size + 1)
    assert_equal %w[/ /tmp], entries(lines).map(&:point)
    assert_equal NS_OK.to_s, edit([mount('/x', 7, 'n' * 255, RIGHTS_RX)]).first
  end

  def test_a_relative_point_joins_the_working_directory
    lines = edit([mount('t', 7, 'tmp', RIGHTS_RW), 'L'], cwd: '/d/e')
    assert_equal '/d/e/t', entries(lines).last.point
  end

  def test_the_table_holds_at_most_its_limit
    mounts = (1...MOUNTS_MAX).map { |index| mount("/m#{index}", index, 't', RIGHTS_RO) }
    lines = edit([*mounts, mount('/over', 99, 't', RIGHTS_RO), bind('/m1', '/over', false), unmount('/m5'),
                  mount('/over', 99, 't', RIGHTS_RO), 'L'])
    assert_equal ['0'] * (MOUNTS_MAX - 1), lines.first(MOUNTS_MAX - 1)
    assert_equal [NS_ELIMIT, NS_ELIMIT, NS_OK, NS_OK].map(&:to_s), lines[MOUNTS_MAX - 1, 4]
    points = entries(lines).map(&:point)
    assert_equal MOUNTS_MAX, points.size
    refute_includes points, '/m5'
    assert_includes points, '/over'
  end

  # Unmounting removes exactly the entry at the point, and the paths below it fall to
  # the mount above; `/` stays.
  def test_unmount_removes_the_entry_at_exactly_its_point
    lines = edit([mount('/tmp', 7, 'tmp', RIGHTS_RW), unmount('/tmp/a'), unmount('/'), unmount('/./'),
                  unmount('/nothing'), unmount('/tmp/.'), unmount('/tmp'), query('/tmp/a'), 'L'])
    assert_equal [NS_OK, NS_EINVAL, NS_EBUSY, NS_EBUSY, NS_EINVAL, NS_OK, NS_EINVAL].map(&:to_s), lines.first(7)
    assert_equal [0, 'tmp/a'], [parse(lines[7]).mount, parse(lines[7]).names]
    assert_equal ['/'], entries(lines).map(&:point)
  end

  # A bind shows what its source resolves to: the same provider or grant, rooted at
  # the source's names, read-only when asked, never wider.
  def test_a_bind_shows_its_source_from_another_point
    lines = edit([mount('/tmp', 7, 'tmp', RIGHTS_RW), bind('/tmp/a/../b/c', '/x', false), bind('/tmp', '/y', true),
                  bind('/x/d', '/z', true), bind('/d', '/w', false), query('/x/e'), query('/z/f'), 'L'])
    assert_equal ['0'] * 5, lines.first(5)
    assert_equal [[2, 'b/c/e'], [4, 'b/c/d/f']], lines[5, 2].map { |line| [parse(line).mount, parse(line).names] }
    assert_equal [Entry.new(point: '/x', kind: NS_SERVER, server: 7, tree: 'tmp', root: '/b/c', rights: RIGHTS_RW),
                  Entry.new(point: '/y', kind: NS_SERVER, server: 7, tree: 'tmp', root: '/', rights: RIGHTS_RO),
                  Entry.new(point: '/z', kind: NS_SERVER, server: 7, tree: 'tmp', root: '/b/c/d', rights: RIGHTS_RO),
                  Entry.new(point: '/w', kind: 0, server: 0, tree: '', root: '/d', rights: RIGHTS_RO)],
                 entries(lines).drop(2)
  end

  def test_a_bind_is_refused_whole
    # With the root's 99 bytes and its `/`, the source's names are 4,095 bytes: they
    # fit the result, but not with the new root's leading `/` and its NUL.
    deep = "/#{(['n' * 199] * 19).join('/')}/#{'n' * 195}"
    lines = edit([bind('/x', '/', false), bind("/x\0", '/y', false), bind('/x', "/y\xff", false),
                  bind('/a', '/a/b', false), bind('/a/b', '/a', false), 'L'])
    assert_equal [NS_EEXIST, NS_EINVAL, NS_EINVAL, NS_OK, NS_OK].map(&:to_s), lines.first(5)
    assert_equal %w[/ /a/b /a], entries(lines).map(&:point)
    # Nothing above a narrowed namespace's mounts can be bound.
    assert_equal NS_ENOENT.to_s, edit([bind('/', '/x', false)], mounts: [['/data', '/']]).first
    # A root that would not fit with its leading `/`.
    assert_equal NS_ENAMETOOLONG.to_s, edit([bind(deep, '/x', false)], mounts: [['/', "/#{'r' * 99}"]]).first
  end

  # A rename or a link takes two paths only where one provider takes both: one
  # grant's tree through one set of rights, whatever the entries' points and roots,
  # or the release file system; any other pair is exdev, and both results are empty.
  def test_two_paths_resolve_together_or_answer_exdev
    exdev = [NS_EXDEV, nil, '', nil, '']
    einval = [NS_EINVAL, nil, '', nil, '']
    cases = { ['/tmp/b', '/tmp/c/d'] => [NS_OK, 1, 'b', 1, 'c/d'], ['/tmp/b', '/x/e'] => [NS_OK, 1, 'b', 4, 'a/e'],
              ['/tmp/b', '/u/b'] => exdev, ['/tmp/b', '/v/b'] => exdev, ['/tmp/b', '/ro/b'] => exdev,
              ['/tmp/b', '/etc'] => exdev, ['/etc', '/tmp/b'] => exdev, ['/etc', '/lib/x'] => [NS_OK, 0, 'etc', 0, 'lib/x'],
              ['/tmp/b', "/x\xff"] => einval, ["/a\0", '/u/b'] => einval, ['/ro/a', '/ro/b'] => [NS_OK, 5, 'a/a', 5, 'a/b'] }
    lines = edit([mount('/tmp', 7, 'tmp', RIGHTS_RW), mount('/u', 7, 'u', RIGHTS_RW), mount('/v', 8, 'tmp', RIGHTS_RW),
                  bind('/tmp/a', '/x', false), bind('/tmp/a', '/ro', true)] + cases.keys.map { |first, second| two(first, second) })
    assert_equal ['0'] * 5, lines.first(5)
    cases.keys.zip(lines.drop(5)).each { |paths, line| assert_equal cases.fetch(paths), pair(line), paths.inspect }
  end

  # A draw keeps the counter's low 32 bits and skips NOFID, also past a wrap.
  def test_a_fid_is_the_low_32_bits_and_never_nofid
    values = [0, 1, 0xffff_fffe, 0xffff_ffff, 0x1_0000_0000, 0x1_0000_0005, 0x1_ffff_ffff, 0xffff_ffff_ffff_ffff]
    lines = edit(values.map { |value| "N #{value}" })
    assert_equal ['1 0', '1 1', '1 4294967294', '0 0', '1 0', '1 5', '0 0', '0 0'], lines
  end

  def test_mutants_of_the_core_fail
    mutants = {
      'a binary search off by one' => ['liberx/release_fs.c', 'low = middle + 1;', 'low = middle + 2;'],
      'a listing that yields a name twice' => ['liberx/release_fs.c',
                                              "erx_release_fs_below(&fs->files[*cursor], file->path, end))\n\t\t(*cursor)++;",
                                              "erx_release_fs_below(&fs->files[*cursor], file->path, end))\n\t\tbreak;"],
      'a file used as a directory answered as missing' => ['liberx/release_fs.c', 'return (ERX_RELEASE_FS_NOT_DIRECTORY);',
                                                           'return (ERX_RELEASE_FS_MISSING);'],
      'a resolver that keeps one ..' => ['liberx/ns.c', "if (walk->count > 0)\n\t\t\t\twalk->count--;",
                                         'if (walk->count > 1) walk->count--;'],
      'a resolver that keeps .' => ['liberx/ns.c', "if (count == 0 || (count == 1 && bytes[start] == '.'))", 'if (count == 0)']
    }
    mutants.each do |label, (source, from, to)|
      driver = build_mutant(source, from, to, name: label.tr(' .', '_'))
      refute_empty exploration_differences(driver), "#{label} went unnoticed"
    end
  end

  def test_limit_mutants_fail
    { 'the name length unchecked' => ['count > ERX_NAME_MAX || ', ''] }.each do |label, (from, to)|
      driver = build_mutant('liberx/ns.c', from, to, name: label.tr(' ', '_'))
      assert_equal NS_OK, ask(['n' * 256], driver: driver).first.status, "#{label} still refused"
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

  # A longer name, or more names, binds and lists and then answers enametoolong at every resolve.
  def test_a_name_erx_ns_resolve_refuses_is_refused_at_bind
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

  # The walk's array overruns, which only a sanitizer run reports.
  def test_the_count_check_removed_is_reported_by_the_address_sanitizer
    skip 'needs ERX_SANITIZERS=address' unless ENV.fetch('ERX_SANITIZERS', '').include?('address')

    driver = build_mutant('liberx/ns.c', ' || walk->count == ERX_NS_NAMES_MAX', '', name: 'the_count_unchecked')
    assert_raises(Erx::Error) { ask([(['n'] * 257).join('/')], driver: driver) }
  end

  private

  def compiler = ENV.fetch('ERX_CLANG', 'clang')

  def build_driver(sources, name:)
    sanitizers = ENV.fetch('ERX_SANITIZERS', '').split(',').reject(&:empty?)
    flags = sanitizers.empty? ? [] : ["-fsanitize=#{sanitizers.join(',')}", '-fno-omit-frame-pointer']
    output = File.join(@directory, name)
    @runner.run([compiler, '-std=c17', '-D_DARWIN_C_SOURCE', '-D_GNU_SOURCE', '-Wall', '-Wextra', '-Werror', '-pedantic', '-O1', '-g',
                 *flags, '-I', File.join(@root, 'include'), *sources,
                 File.join(@root, 'test/fixtures/release_fs_driver.c'), '-o', output],
                name: "release-fs-#{name}", deadline: 120)
    output
  end

  def build_mutant(source, from, to, name:)
    text = File.read(File.join(@root, source))
    assert_includes text, from, "the #{name} seed no longer applies"
    mutated = File.join(@directory, "#{name}.c")
    File.write(mutated, text.sub(from) { to })
    others = CORE.reject { |other| other == source }.map { |other| File.join(@root, other) }
    build_driver([mutated, *others], name: "mutant_#{name}")
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
    sources = %w[liberx/release.c liberx/generated/abi_reader.c kernel/core/pack.c kernel/crypto/blake3/blake3.c
                 kernel/crypto/blake3/blake3_portable.c test/fixtures/release_driver.c]
    @runner.run([compiler, '-std=c17', '-Wall', '-Wextra', '-Werror', '-pedantic', '-O1', '-g', *flags,
                 '-I', File.join(@root, 'include'), '-I', File.join(@root, 'kernel/crypto'),
                 *sources.map { |source| File.join(@root, source) }, '-o', output],
                name: 'release-driver-build', deadline: 120)
    output
  end

  def hex(bytes) = bytes.empty? ? '-' : bytes.unpack1('H*')
  def unhex(text) = text == '-' ? '' : [text].pack('H*')

  # One run of the driver's table commands after the tree, the mounts and the working
  # directory; answers its output lines as they are.
  def edit(commands, cwd: '/', mounts: [['/', '/']])
    lines = TREE.map { |file| "F #{hex(file)}" } + mounts.map { |point, root| "M #{hex(point)} #{hex(root)}" } +
            ["C #{hex(cwd)}"] + commands
    input = File.join(@directory, 'commands')
    File.write(input, "#{lines.join("\n")}\n")
    record = @runner.run([@driver, input], name: 'release-fs-driver', deadline: 300)
    File.readlines(record.fetch('log'), chomp: true)
  end

  def mount(point, server, tree, rights) = "S #{hex(point.b)} #{server} #{hex(tree.b)} #{rights}"
  def bind(from, to, read_only) = "B #{hex(from.b)} #{hex(to.b)} #{read_only ? 1 : 0}"
  def unmount(point) = "U #{hex(point.b)}"
  def query(path) = "Q #{hex(path.b)}"
  def two(first, second) = "T #{hex(first.b)} #{hex(second.b)}"

  def pair(line)
    status, first_mount, first_names, second_mount, second_names = line.split(' ')
    [Integer(status), first_mount == '-' ? nil : Integer(first_mount), unhex(first_names),
     second_mount == '-' ? nil : Integer(second_mount), unhex(second_names)]
  end

  def entries(lines)
    lines.select { |line| line.start_with?('E ') }.map do |line|
      _, point, kind, server, tree, root, rights = line.split(' ')
      Entry.new(point: unhex(point), kind: Integer(kind), server: Integer(server), tree: unhex(tree),
                root: unhex(root), rights: Integer(rights))
    end
  end

  # One run: the tree, the mounts, then the paths from one working directory.
  def ask(paths, cwd: '/', mounts: [['/', '/']], driver: @driver)
    commands = TREE.map { |file| "F #{hex(file)}" } +
               mounts.map { |point, root| "M #{hex(point)} #{hex(root)}" } +
               ["C #{hex(cwd)}"] + paths.map { |path| "Q #{hex(path.b)}" }
    input = File.join(@directory, 'commands')
    File.write(input, "#{commands.join("\n")}\n")
    record = @runner.run([driver, input], name: 'release-fs-driver', deadline: 300)
    File.readlines(record.fetch('log'), chomp: true).map { |line| parse(line) }
  end

  def parse(line)
    status, mount, nnames, names, path, kind, file, listing = line.split(' ', 8)
    return Answer.new(status: Integer(status), mount: nil, nnames: 0, names: '', path: '', kind: nil, file: nil, listing: []) if mount.nil?

    Answer.new(status: Integer(status), mount: mount == '-' ? nil : Integer(mount), nnames: Integer(nnames),
               names: unhex(names), path: unhex(path), kind: Integer(kind), file: Integer(file),
               listing: listing == '-' ? [] : listing.split(','))
  end

  # The design's rules, plainly.
  def model(path, cwd:)
    kept = path.start_with?('/') ? [] : cwd.split('/').reject(&:empty?)
    path.split('/', -1).each do |name|
      case name
      when '', '.' then next
      when '..' then kept.pop
      else kept << name
      end
    end
    names = kept.join('/')
    kind = model_kind(names)
    [names, "/#{names}", kind, kind == KIND_FILE ? TREE.index(names) : -1, kind == KIND_DIRECTORY ? model_listing(names) : []]
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

  def all_paths
    paths = [[ALPHABET, DEPTH], [WIDE_ALPHABET, WIDE_DEPTH]].flat_map do |alphabet, deepest|
      (1..deepest).flat_map { |depth| alphabet.repeated_permutation(depth).map { |names| names.join('/') } }
    end
    paths.uniq.reject(&:empty?).flat_map { |path| [path, "/#{path}"] }
  end

  def exploration_differences(driver)
    paths = all_paths
    WORKING_DIRECTORIES.flat_map do |cwd|
      paths.zip(ask(paths, cwd: cwd, driver: driver)).filter_map do |path, answer|
        names, normal, kind, file, listing = model(path, cwd: cwd)
        got = [answer&.status, answer&.mount, answer&.nnames, answer&.names, answer&.path, answer&.kind, answer&.file,
               answer&.listing]
        want = [NS_OK, 0, names.split('/').size, names, normal, kind, file, listing]
        "#{cwd} #{path}: #{got} != #{want}" if got != want
      end
    end
  end
end
