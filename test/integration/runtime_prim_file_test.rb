# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'digest'
require 'fileutils'
require 'minitest/autorun'
require 'open3'
require 'timeout'
require 'tmpdir'
require_relative '../../tools/lib/erx/abi'
require_relative '../../tools/lib/erx/pack_tools'
require_relative '../../tools/lib/erx/pack_wire'
require_relative '../../tools/lib/erx/runner'
require_relative '../../tools/lib/erx/runtime'
require_relative '../../tools/lib/erx/runtime_seam'

# The release file system against stock's prim_file (design-runtime.md, Files and
# Verification). The hosted runtime runs one set of prim_file calls twice over the
# same files: over a test archive, booting through erl_prim_loader from it alone, and
# with stock's unix_prim_file.c over the tree unpacked, read-only. The two transcripts
# agree line by line except for the paths named below.
#
# `make check-runtime-hosted` builds the runtime and runs this. It is excused from
# `make check`, which does not build the runtime.
class RuntimePrimFileTest < Minitest::Test
  ROOT = File.expand_path('../..', __dir__)
  OUTPUT = Erx::Runtime.output(root: ROOT)
  APPLICATIONS = %w[kernel stdlib compiler].freeze
  RUN_SECONDS = 180
  # A leak of one small resource per call, over 10,000 calls, grows past this.
  RESOURCE_GROWTH_BYTES = 256 * 1024

  # What lexical `.` and `..` make of a path stock's stat refuses. `release` is the
  # answer's first word on this provider; the operations each path differs on all
  # follow from it. Each is a stated difference of the design.
  ENOTDIR_THEN_FILE = %w[a.txt/. a.txt/ a.txt/../sub/b.txt].freeze
  ENOENT_THEN_FILE = %w[missing/../a.txt missing/../sub/b.txt].freeze
  # A name over the limit is refused before the walk finds `missing`, and macOS's
  # own path limit is 1,024 bytes where the design's is 4,096.
  LIMITS = {
    "missing/#{'n' * 256}" => [:enoent, :enametoolong],
    "#{'nnnnnnnnnn/' * 100}x" => [:enametoolong, :enoent]
  }.freeze

  class << self
    attr_accessor :fixture
  end

  Fixture = Data.define(:directory, :tree, :archive, :release, :stock, :release_status, :stock_status)

  def setup
    Erx::Runtime.check_current(root: ROOT)
    self.class.fixture ||= build_fixture
    @fixture = self.class.fixture
  end

  Minitest.after_run do
    FileUtils.chmod_R('u+w', fixture.directory) if fixture
    FileUtils.remove_entry(fixture.directory) if fixture
  end

  def test_both_runs_finish
    assert_equal 0, @fixture.stock_status, @fixture.stock.last(30).join("\n")
    assert_equal 0, @fixture.release_status, @fixture.release.last(30).join("\n")
    assert_includes @fixture.release, "end\tok"
    assert_includes @fixture.stock, "end\tok"
  end

  def test_results_agree_with_stock_except_where_named
    release = table(@fixture.release)
    stock = table(@fixture.stock)
    assert_operator stock.size, :>, 200, 'the comparison ran its corpus'
    differences = (stock.keys | release.keys).filter_map do |key|
      next if release[key] == stock[key] || key.start_with?('pin ', 'resources')
      next if named?(key)

      "#{describe(key)}\n  stock:   #{stock[key]}\n  release: #{release[key]}"
    end
    assert_empty differences, differences.join("\n")
  end

  # Both pins hold the design's sentence: `f/.` is `f`, where stock's stat answers enotdir.
  def test_the_lexical_differences_are_pinned
    release = table(@fixture.release)
    stock = table(@fixture.stock)
    assert_match(/\A\{ok,regular,6,read,/, release.fetch(line_key('file_info', 'a.txt/.')))
    assert_equal '{error,enotdir}', stock.fetch(line_key('file_info', 'a.txt/.'))
    assert_match(/\A\{ok,regular,6,read,/, release.fetch(line_key('file_info', 'a.txt/')))
    assert_equal '{error,enotdir}', stock.fetch(line_key('file_info', 'a.txt/'))
    assert_match(/\A\{ok,regular,6,read,/, release.fetch(line_key('file_info', 'missing/../a.txt')))
    assert_equal '{error,enoent}', stock.fetch(line_key('file_info', 'missing/../a.txt'))
    assert_equal release.fetch(line_key('read_file', 'a.txt')), release.fetch(line_key('read_file', 'missing/../a.txt'))
    LIMITS.each do |path, (from_stock, from_release)|
      assert_equal "{error,#{from_stock}}", stock.fetch(line_key('file_info', path)), path
      assert_equal "{error,#{from_release}}", release.fetch(line_key('file_info', path)), path
    end
  end

  def test_the_provider_holds_its_fixed_answers
    release = table(@fixture.release)
    assert_equal '{1,0,0,0,0,0,0,0,0}', release.fetch('pin info')
    assert_equal '{directory,365,0,1}', release.fetch('pin top')
    assert_equal '{error,enotsup}', release.fetch('pin advise')
    assert_equal '{error,enotsup}', release.fetch('pin allocate')
    assert_equal 'ok', release.fetch('pin sync')
    %w[open_write open_new open_append make_dir delete del_dir rename make_link make_symlink
       write_file_info].each { |name| assert_equal '{error,erofs}', release.fetch("pin #{name}"), name }
    assert_equal '{error,enotsup}', release.fetch('pin open_directory')
    assert_equal '{error,enotsup}', release.fetch('pin altname')
  end

  def test_modules_load_from_the_archive_through_erl_prim_loader
    release = table(@fixture.release)
    assert_match(%r{\A\["/+lib/stdlib/ebin/lists\.beam","/+lib/kernel/ebin/file\.beam","/+lib/compiler/ebin/compile\.beam"\]\z},
                 release.fetch('pin code'))
    assert_equal '{module,compile}', release.fetch('pin load')
    assert_equal '<<"alpha\n">>', release.fetch('loader_get_file')
    assert_equal 'error', release.fetch('loader_missing')
  end

  def test_close_releases_the_resource
    [@fixture.release, @fixture.stock].each do |transcript|
      reads, opens = table(transcript).fetch('resources').split.map { |number| Integer(number) }
      assert_operator reads, :<, RESOURCE_GROWTH_BYTES, 'read_file left resources behind'
      assert_operator opens, :<, RESOURCE_GROWTH_BYTES, 'open and close left resources behind'
    end
  end

  def test_a_damaged_index_is_refused_with_the_check_named
    damaged = File.join(@fixture.directory, 'damaged.pack')
    bytes = File.binread(@fixture.archive)
    bytes.setbyte(4096 - 1, 0xff) # inside the index run: the hash covers it
    bytes.setbyte(200, bytes.getbyte(200) ^ 0x40)
    File.binwrite(damaged, bytes)
    output, status = run_beam(damaged, '/', 'release', boot: '/bin/start')
    refute status.success?, output.last(20).join("\n")
    assert(output.any? { |line| line.include?('boot archive refused: index_hash') }, output.last(20).join("\n"))
  end

  private

  # A path over 64 bytes appears on its line as its MD5.
  def line_key(operation, path)
    bytes = path.b
    "#{operation} #{(bytes.bytesize > 64 ? Digest::MD5.digest(bytes) : bytes).unpack1('H*')}"
  end

  # stock passes bytes that are not UTF-8 to the host, whose file system misses them.
  def named?(key)
    _operation, hexadecimal = key.split(' ', 2)
    named = ENOTDIR_THEN_FILE + ENOENT_THEN_FILE + LIMITS.keys + ["\xFF\xFE".b]
    named.any? { |path| line_key('', path).strip == hexadecimal }
  end

  def describe(key)
    operation, hexadecimal = key.split(' ', 2)
    hexadecimal ? "#{operation} #{[hexadecimal].pack('H*').inspect}" : key
  end

  def table(transcript)
    transcript.filter_map do |line|
      key, value = line.split("\t", 2)
      [key, value] if value
    end.to_h
  end

  def build_fixture
    directory = File.realpath(Dir.mktmpdir('erx-prim-file-'))
    tree = File.join(directory, 'tree')
    fill_tree(tree)
    compile_driver(tree)
    archive = File.join(directory, 'release.pack')
    pack(tree, archive, directory)
    FileUtils.chmod_R('a-w', tree)
    release, release_status = run_beam(archive, '/', 'release', boot: '/bin/start')
    stock, stock_status = run_beam(nil, tree, 'stock', boot: "#{tree}/bin/start")
    Fixture.new(directory: directory, tree: tree, archive: archive, release: release, stock: stock,
                release_status: release_status.exitstatus, stock_status: stock_status.exitstatus)
  end

  # The corpus, the applications, the tracked boot script and what an archive must hold.
  def fill_tree(tree)
    corpus = File.join(tree, 'corpus')
    FileUtils.mkdir_p(File.join(corpus, 'sub/deep'))
    File.write(File.join(corpus, 'a.txt'), "alpha\n")
    File.write(File.join(corpus, 'empty'), '')
    File.binwrite(File.join(corpus, 'big.bin'), (0...100_000).map { |index| (index * 31) & 0xff }.pack('C*'))
    File.write(File.join(corpus, 'sub/b.txt'), "beta\n")
    File.write(File.join(corpus, 'sub/deep/c.txt'), "gamma\n")
    File.write(File.join(corpus, 'sub-x'), "sorts before sub/\n")
    File.write(File.join(corpus, 'sub0'), "sorts after sub/\n")
    File.write(File.join(tree, 'manifest'), "test manifest\n")
    File.write(File.join(tree, 'root'), "a root image's place\n")
    FileUtils.mkdir_p(File.join(tree, 'bin'))
    FileUtils.cp(File.join(OUTPUT.root, 'bootstrap/bin/start.boot'), File.join(tree, 'bin/start.boot'))
    APPLICATIONS.each do |application|
      ebin = File.join(tree, 'lib', application, 'ebin')
      FileUtils.mkdir_p(ebin)
      FileUtils.cp(Dir.glob(File.join(OUTPUT.root, 'lib', application, 'ebin', '*.{beam,app}')), ebin)
    end
    FileUtils.mkdir_p(File.join(tree, 'test/ebin'))
  end

  # The hosted runtime over stock's layer compiles the driver.
  def compile_driver(tree)
    source = File.expand_path('prim_file_compare.erl', __dir__)
    expression = "{ok,_}=compile:file(\"#{source}\",[{outdir,\"#{tree}/test/ebin\"},{i,\"#{OUTPUT.root}/lib\"}]),halt()."
    output, status = capture_beam({}, OUTPUT.root, ['-noshell', '-pa', "#{OUTPUT.root}/lib/compiler/ebin", '-eval', expression],
                                  boot: File.join(OUTPUT.root, 'bootstrap/bin/start'))
    assert status.success?, output.join("\n")
  end

  def pack(tree, archive, directory)
    runner = Erx::Runner.new(owner_root: directory, log_dir: File.join(directory, 'logs'))
    tools = Erx::PackTools.build(root: ROOT, owner_root: directory, directory: File.join(directory, 'tools'),
                                 runner: runner, compiler: ENV.fetch('ERX_CLANG', 'clang'))
    codec = Erx::ABI::Codec.new(Erx::ABI::Generator.plan(root: ROOT).schema)
    system = codec.member('entry_flags', 'system')
    rows = Dir.glob('**/*', base: tree).select { |path| File.file?(File.join(tree, path)) }.sort.map do |path|
      name = "system/#{path}"
      kind = codec.member('entry_kind', name == 'system/root' ? 'image' : 'file')
      { 'path' => name, 'kind' => kind, 'flags' => system, 'size' => File.size(File.join(tree, path)),
        'snapshot' => File.join(tree, path) }
    end.sort_by { |row| row.fetch('path').b }
    writer = Erx::PackWire.new(codec: codec, hasher: Erx::PackHasher.new(helper: tools.fetch('hasher'), runner: runner))
    File.open(archive, 'wb+') do |output|
      writer.write(rows: rows, root_entry: rows.index { |row| row.fetch('path') == 'system/root' },
                   build_kind: 'development', output: output, budget: 512 * 1024 * 1024)
    end
  end

  def run_beam(archive, root, mode, boot:)
    environment = archive ? { 'ERX_RELEASE_ARCHIVE' => archive } : {}
    capture_beam(environment, root, ['-noshell', '-pa', "#{root == '/' ? '' : root}/test/ebin",
                                     '-run', 'prim_file_compare', 'main', root, mode], boot: boot)
  end

  # Output and exit status of a beam with the root and boot script given; no shell.
  def capture_beam(extra_environment, root, arguments, boot:)
    bin = File.dirname(OUTPUT.beam)
    environment = Erx::Oracle::CLEAN_ERLANG_ENV.merge(
      'BINDIR' => bin, 'ROOTDIR' => root, 'EMU' => 'beam', 'PROGNAME' => 'erl', 'HOME' => nil, 'ERL_CRASH_DUMP_BYTES' => '0'
    ).merge(extra_environment)
    command = [OUTPUT.beam, '--', '-root', root, '-bindir', bin, '-progname', 'erl', '--', '-home', '/', '--',
               '-boot', boot, *arguments]
    output, status = Timeout.timeout(RUN_SECONDS) do
      Open3.capture2e(environment, 'gtimeout', '-k', '10', RUN_SECONDS.to_s, *command, stdin_data: '', chdir: '/')
    end
    [output.lines(chomp: true), status]
  end
end
