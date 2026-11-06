# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'digest'
require 'fileutils'
require 'find'
require 'minitest/autorun'
require 'open3'
require 'timeout'
require 'tmpdir'
require_relative '../../tools/lib/erx/abi'
require_relative '../../tools/lib/erx/pack_tools'
require_relative '../../tools/lib/erx/pack_wire'
require_relative '../../tools/lib/erx/release'
require_relative '../../tools/lib/erx/runner'
require_relative '../../tools/lib/erx/runtime'
require_relative '../../tools/lib/erx/runtime_seam'

# The release file system against stock's prim_file (design-runtime.md, Files and
# Verification). One set of prim_file calls runs twice over the same files: on the
# hosted runtime over a test archive, booting through erl_prim_loader from it alone,
# and on stock OTP's own emulator of the same release over the tree unpacked,
# read-only. The two transcripts agree line by line except for the paths named below.
#
# `make check-runtime-hosted` builds the runtime and runs this. It is excused from
# `make check`, which does not build the runtime.
class RuntimePrimFileTest < Minitest::Test
  ROOT = File.expand_path('../..', __dir__)
  OUTPUT = Erx::Runtime.output(root: ROOT)
  # The bootstrap boot script's code path names OTP's three; erXos's own, whose watchdog
  # kernel_sup starts, join it by -pa.
  APPLICATIONS = [*%w[kernel stdlib compiler], *Erx::ErlangApps::APPLICATIONS].freeze
  RUN_SECONDS = 180
  # A leak of one small resource per call, over 10,000 calls, grows past this.
  RESOURCE_GROWTH_BYTES = 256 * 1024

  OPERATIONS = %w[read_file file_info link_info read_link list_dir handle set_cwd].freeze
  # Lexical `.` and `..`: each path answers, on every operation, as the path beside it,
  # where stock's stat refuses it with enotdir or enoent.
  LEXICAL = { 'a.txt/.' => 'a.txt', 'a.txt/' => 'a.txt', 'a.txt/../sub/b.txt' => 'sub/b.txt',
              'missing/../a.txt' => 'a.txt', 'missing/../sub/b.txt' => 'sub/b.txt' }.freeze
  # A name over the limit is refused before the walk finds `missing`, and macOS's own
  # path limit is 1,024 bytes where the design's is 4,096.
  Refused = Data.define(:stock, :release)
  LIMITS = { "missing/#{'n' * 256}" => Refused.new(stock: 'enoent', release: 'enametoolong'),
             "#{'nnnnnnnnnn/' * 100}x" => Refused.new(stock: 'enametoolong', release: 'enoent') }.freeze
  # Not UTF-8: refused here, and left to the host's file system by stock.
  NOT_UTF8 = "\xFF\xFE".b.freeze

  class << self
    attr_accessor :fixture
  end

  Fixture = Data.define(:directory, :tree, :archive, :release, :stock, :release_status, :stock_status)

  def setup
    Erx::Runtime.check_current(root: ROOT)
    self.class.fixture ||= build_fixture
    @fixture = self.class.fixture
  end

  # The corpus leaves directories its owner cannot write or search, which would refuse
  # removal of their entries, and links that may dangle. Removal needs only each
  # directory's owner bits; Find walks by lstat, so no link is followed or stat'ed, and
  # yields a directory before it reads it.
  Minitest.after_run do
    next unless fixture

    Find.find(fixture.directory) do |entry|
      status = File.lstat(entry)
      File.chmod((status.mode & 0o7777) | 0o700, entry) if status.directory?
    end
    FileUtils.remove_entry(fixture.directory)
  end

  def test_both_runs_finish
    assert_equal 0, @fixture.stock_status, @fixture.stock.last(30).join("\n")
    assert_equal 0, @fixture.release_status, @fixture.release.last(30).join("\n")
    assert_includes @fixture.release, "end\tok"
    assert_includes @fixture.stock, "end\tok"
  end

  # A changed byte behind an intact index: each open of that one file answers eio where it
  # answered with data, and the changed bytes come back nowhere.
  def test_a_changed_byte_is_refused_at_open
    intact = "sorts before sub/\n".b
    changed = "torts before sub/\n".b
    bytes = File.binread(@fixture.archive)
    place = bytes.index(intact)
    bytes[place, intact.bytesize] = changed
    damaged = File.join(@fixture.directory, 'damaged.pack')
    File.binwrite(damaged, bytes)
    lines, status = run_beam(damaged, '/', 'release', boot: '/bin/start')
    assert_equal 0, status.exitstatus, lines.last(30).join("\n")
    assert_includes @fixture.release.join("\n"), Digest::MD5.digest(intact).bytes.join(','), 'the corpus reads this file'
    refute_includes lines.join("\n"), Digest::MD5.digest(changed).bytes.join(',')
    refute_includes lines.join("\n"), 'torts before'
    # Two runs' memory figures differ by nature, and test_results_agree_with_stock... exempts them too.
    # The restart case's supervisor report carries the time of each run.
    other = (lines - @fixture.release).reject { |line| line.start_with?('resources', '=SUPERVISOR REPORT') }
    diagnostics, refused = other.partition { |line| line.start_with?('prim_file: ') }
    assert_includes diagnostics.first.to_s, 'file_hash'
    name = 'sub-x'.unpack1('H*')
    assert_equal ["read_file #{name}\t{error,eio}", "handle #{name}\t{error,eio}"], refused
  end

  def test_results_agree_with_stock_except_where_named
    release = table(@fixture.release)
    stock = table(@fixture.stock)
    assert_operator stock.size, :>, 200, 'the comparison ran its corpus'
    differences = (stock.keys | release.keys).filter_map do |key|
      next if release[key] == stock[key] || key.start_with?('pin ', 'ns ', 'remote ', 'resources', 'tmp')
      next if named?(key)

      "#{describe(key)}\n  stock:   #{stock[key]}\n  release: #{release[key]}"
    end
    assert_empty differences, differences.join("\n")
  end

  # /tmp against stock OTP in a fresh host directory (design-tmp.md, Verification, "Against
  # stock OTP"): every step agrees but those named here, each as [stock, release], a
  # difference the design states (Differences from stock OTP) or one TODO.md records. A
  # last `..` of a removal and a last `.` or `..` of a rename answer as Linux's
  # (ENOTEMPTY, which prim_file answers as eexist, and EBUSY), where macOS answers einval.
  TMP_DIFFERENCES = {
    'tmp del_dir child/..' => ['{error,einval}', '{error,eexist}'],
    'tmp del_dir other full' => ['{error,einval}', '{error,eexist}'],
    'tmp rename child/..' => ['{error,einval}', '{error,ebusy}'],
    'tmp rename to child/.' => ['{error,einval}', '{error,ebusy}']
  }.freeze

  def test_tmp_agrees_with_stock_except_where_named
    release = table(@fixture.release).select { |key, _| key.start_with?('tmp ') }
    stock = table(@fixture.stock).select { |key, _| key.start_with?('tmp ') }
    assert_operator stock.size, :>, 30, 'the /tmp corpus ran'
    differences = (stock.keys | release.keys).filter_map do |key|
      pinned = TMP_DIFFERENCES[key]
      next if pinned ? [stock[key], release[key]] == pinned : release[key] == stock[key]

      "#{key}\n  stock:   #{stock[key]}\n  release: #{release[key]}"
    end
    assert_empty differences, differences.join("\n")
  end

  # /tmp's own cases, which stock has no counterpart for. A write past the cap is refused
  # whole: the file it made stays, empty. A restart leaves /tmp empty and the old open file
  # answering eio, and the restart leaves no old owner alive. A
  # working directory is a path: on a grant that ended it answers eio, and once its mount
  # is gone it reaches the release file system.
  TMP_ERXOS = {
    'tmpx limit' => 'true', 'tmpx small fits' => 'ok', 'tmpx small past' => '{error,enospc}',
    'tmpx small b' => '{ok,regular,0,read_write,420,1}', 'tmpx small write' => 'ok', 'tmpx small kept' => '{ok,<<3>>}',
    'tmpx zero list' => '{ok,[]}', 'tmpx zero write' => '{error,enospc}', 'tmpx zero dir' => '{error,enospc}',
    'tmpx restarted' => 'ok', 'tmpx old fd' => '{error,eio}', 'tmpx empty' => '{ok,[]}',
    'tmpx inode above' => 'true', 'tmpx old owners counted' => 'true', 'tmpx no old owner alive' => 'none',
    'tmpx held while open' => 'true', 'tmpx held after close' => 'true',
    'tmpx held while owner lives' => 'true', 'tmpx held after owner killed' => 'ok',
    'tmpx concurrent renames' => '{0,true,800,1,true}', 'tmpx concurrent fill' => '{[enospc],true,true}',
    'tmpx cwd path' => '{ok,"/tmp/seq/w"}', 'tmpx small cwd' => 'ok',
    'tmpx small cwd info' => '{ok,regular,60000,read_write,420,1}', 'tmpx small cwd ended' => '{error,eio}',
    'tmpx small cwd unmounted' => '{error,enoent}', 'tmpx small cwd kept' => '{ok,"/small"}'
  }.freeze

  # The working directory in /tmp, by the client's error steps (design-files.md, Erlang
  # clients): stock answers the same, and these pin what both answer.
  TMP_CWD = {
    'tmp cwd set' => 'ok', 'tmp cwd get' => '{ok,"w"}', 'tmp cwd write' => 'ok',
    'tmp cwd read' => '{ok,<<"rel">>}', 'tmp cwd read absolute' => '{ok,<<"rel">>}',
    'tmp cwd list' => '{ok,["f","sub"]}', 'tmp cwd set file' => '{error,enotdir}',
    'tmp cwd set missing' => '{error,enoent}', 'tmp cwd kept' => '{ok,"w"}',
    'tmp cwd set file/' => '{error,enotdir}', 'tmp cwd set sub' => 'ok', 'tmp cwd sub' => '{ok,"sub"}',
    'tmp cwd set ..' => 'ok', 'tmp cwd set unsearchable' => '{error,eacces}', 'tmp cwd set link' => 'ok',
    'tmp cwd link' => '{ok,"w"}', 'tmp cwd set link out' => 'ok', 'tmp cwd out' => '{ok,"corpus"}',
    'tmp del_dir cwd full' => '{error,einval}', 'tmp del_dir cwd sub/..' => '{error,einval}',
    'tmp del_dir cwd empty' => 'ok', 'tmp cwd gone write' => '{error,enoent}',
    'tmp cwd back' => 'ok', 'tmp cwd back where' => 'true'
  }.freeze

  def test_tmp_working_directory
    release = table(@fixture.release)
    TMP_CWD.each { |step, want| assert_equal want, release[step], step }
  end

  # Reads and writes past the client's 64 KiB unit (file_SUITE's segment_read and
  # segment_write): a read answers every byte up to the end, as stock's does, and these
  # pin what both answer.
  TMP_LARGE = {
    'tmp large write' => 'ok', 'tmp large read_file' => '{ok,262144,true}',
    'tmp large read' => '{ok,262144,true}', 'tmp large read at eof' => 'eof',
    'tmp large read past eof' => '{ok,192144,true}', 'tmp large pread' => '{ok,262144,true}',
    'tmp large pread past eof' => '{ok,162144,true}',
    'tmp large pread list' => '{ok,70000,192144,eof,true}', 'tmp large pwrite list' => 'ok',
    'tmp large pwrite list back' => '{ok,262144,true}', 'tmp large segments' => '[ok]',
    'tmp large segments back' => '{ok,262144,true}', 'tmp large delete' => '{ok,ok}'
  }.freeze

  def test_tmp_large_reads_and_writes
    release = table(@fixture.release)
    stock = table(@fixture.stock)
    TMP_LARGE.each do |step, want|
      assert_equal want, stock[step], "stock #{step}"
      assert_equal want, release[step], step
    end
  end

  # The read-ahead buffer (file_SUITE's read_ahead): reads answer what it holds, a later
  # write through another file notwithstanding, and position, write and truncate empty it
  # at the offset the reads reached. read_line buffers as stock's does.
  TMP_AHEAD = {
    'tmp ahead read' => '{ok,"asdfghjkl"}', 'tmp ahead cached' => '{ok,"asdfghjkl"}',
    'tmp ahead at end' => 'eof', 'tmp ahead position' => '{ok,9}',
    'tmp ahead after position' => '{ok,"qwertyuio"}',
    'tmp ahead sized' => '[{ok,<<"asd">>},{ok,<<"fgh">>},{ok,<<"jklqwertyuio">>}]',
    'tmp ahead read rw' => '{ok,<<"asd">>}', 'tmp ahead write rw' => 'ok',
    'tmp ahead offset rw' => '{ok,6}', 'tmp ahead read after write' => '{ok,<<"jkl">>}',
    'tmp ahead truncate' => 'ok', 'tmp ahead file' => '{ok,<<"asdXYZjkl">>}',
    'tmp ahead line' => '{ok,<<"one\\n">>}',
    'tmp ahead line cached' => '[{ok,<<"two\\n">>},{ok,<<"three">>},eof]',
    'tmp ahead line position' => '{ok,14}', 'tmp ahead delete' => 'ok'
  }.freeze

  def test_tmp_read_ahead
    release = table(@fixture.release)
    stock = table(@fixture.stock)
    TMP_AHEAD.each do |step, want|
      assert_equal want, stock[step], "stock #{step}"
      assert_equal want, release[step], step
    end
  end

  def test_tmp_serves_the_domain
    release = table(@fixture.release)
    TMP_ERXOS.each { |step, want| assert_equal want, release[step], step }
  end

  # The design's sentence: `f/.` is `f`, where stock's stat answers enotdir.
  def test_the_lexical_differences_are_pinned
    release = table(@fixture.release)
    stock = table(@fixture.stock)
    LEXICAL.each do |path, same_as|
      OPERATIONS.each do |operation|
        assert_equal release.fetch(line_key(operation, same_as)), release.fetch(line_key(operation, path)),
                     "#{operation} #{path}"
      end
    end
    assert_match(/\A\{ok,regular,6,read,/, release.fetch(line_key('file_info', 'a.txt/.')))
    assert_equal '{error,enotdir}', stock.fetch(line_key('file_info', 'a.txt/.'))
    assert_equal '{error,enotdir}', stock.fetch(line_key('file_info', 'a.txt/'))
    assert_equal '{error,enoent}', stock.fetch(line_key('file_info', 'missing/../a.txt'))
  end

  def test_the_limits_and_refusals_are_pinned
    release = table(@fixture.release)
    stock = table(@fixture.stock)
    LIMITS.each do |path, refused|
      assert_refused(release, path, refused.release)
      assert_refused(stock, path, refused.stock)
    end
    (OPERATIONS - ['set_cwd']).each do |operation|
      assert_equal '{error,einval}', release.fetch(line_key(operation, NOT_UTF8)), operation
    end
    # prim_file's Erlang side refuses this one before the NIF, as on stock.
    assert_equal stock.fetch(line_key('set_cwd', NOT_UTF8)), release.fetch(line_key('set_cwd', NOT_UTF8))
  end

  def test_the_provider_holds_its_fixed_answers
    release = table(@fixture.release)
    assert_equal '{1,0,0,0,0,0,0,0,0}', release.fetch('pin info')
    assert_equal '{directory,365,0,1}', release.fetch('pin top')
    assert_equal '{error,enotsup}', release.fetch('pin advise')
    assert_equal '{error,enotsup}', release.fetch('pin allocate')
    assert_equal 'ok', release.fetch('pin sync')
    assert_equal '{error,erofs}', release.fetch('pin write')
    %w[open_write open_new open_append make_dir delete del_dir rename make_link make_symlink
       write_file_info].each { |name| assert_equal '{error,erofs}', release.fetch("pin #{name}"), name }
    assert_equal '{error,enotsup}', release.fetch('pin open_directory')
    assert_equal '{error,enotsup}', release.fetch('pin altname')
  end

  # erx_ns changes the namespace for the whole runtime: a grant's paths reach
  # erx_file_remote, unmounting gives them back to the release, and a grant whose
  # process ended answers eio until it is unmounted. A path reaches erx_file_remote as
  # prim_file encodes it, with the NUL its NIF hands to C.
  def test_a_mount_routes_its_paths_to_erx_file_remote
    release = table(@fixture.release)
    { 'ns before' => '{error,enoent}', 'ns mount' => 'ok', 'ns info' => "{ok,directory,read_write,#{0o40755}}",
      'ns read' => '{error,eisdir}', 'ns again' => '{error,eexist}', 'ns bad tree' => '{error,einval}',
      'ns bind' => 'ok', 'ns bound' => "{ok,regular,0,read_write,#{0o100644}}", 'ns unmount' => 'ok',
      'ns after' => '{error,enoent}', 'ns root' => '{error,ebusy}', 'ns mount gone' => 'ok',
      'ns gone' => '{error,eio}', 'ns unmount gone' => 'ok', 'ns unmount bound' => 'ok', 'ns fids' => '{true,1}',
      'ns ro bind' => '{{error,enoent},read_file_info,<<"test">>,ro,[{<<"/ro">>,<<"a">>,<<"a/c">>},1,<<47,114,111,47,99,0>>]}',
      'ns rw mount' => '{ok,make_dir,<<"test">>,rw,[{<<"/tmp">>,<<>>,<<"c">>},<<47,116,109,112,47,99,0>>]}',
      'ns rename one' => '{{error,enoent},rename,<<"test">>,rw,[{<<"/tmp">>,<<>>,<<"x">>},{<<"/tmp">>,<<>>,<<"a/y">>},<<47,116,109,112,47,120,0>>,<<47,116,109,112,47,97,47,121,0>>]}',
      'ns rename two' => '{{error,exdev},none}', 'ns rename ro' => '{{error,exdev},none}',
      'ns rename local' => '{{error,exdev},none}',
      'ns link one' => '{{error,enoent},make_link,<<"u">>,rw,[{<<"/u">>,<<>>,<<"x">>},{<<"/u">>,<<>>,<<"y">>},<<47,117,47,120,0>>,<<47,117,47,121,0>>]}',
      'ns link two' => '{{error,exdev},none}' }.each do |step, want|
      assert_equal want, release.fetch(step), step
    end
  end

  DIRECTORY = "{ok,directory,read_write,#{0o40755}}"
  FILE = "{ok,regular,0,read_write,#{0o100644}}"
  CHANGED = "{ok,regular,0,read_write,#{0o104600}}"
  LINK = "{ok,symlink,read_write,#{0o120777}}"
  # erx_file_remote's answers over erx_fs_test_tree (design-files.md, Erlang clients,
  # and the cases of design-tmp.md's verification that need no stock OTP): each path
  # operation, the error steps in order, the #file_info{} fields, a read-only entry's
  # erofs before anything is sent, exdev, no fid left behind, hostile replies, paths
  # written with a trailing "/" (Linux's answers) and symbolic links followed within the
  # grant and out of it, to 40 links.
  REMOTE = {
    'info dir' => DIRECTORY, 'info file' => FILE, 'info root' => DIRECTORY,
    'info missing' => '{error,enoent}', 'info past a file' => '{error,enotdir}',
    'info link' => "{ok,symlink,read_write,#{0o120777}}", 'info through a link' => DIRECTORY,
    'info fields' => '{0,1,4,0,0,0,true,true}', 'info same device' => 'true',
    'read link' => '{ok,"a"}', 'read link of a file' => '{error,einval}',
    'list' => '{ok,["a","f","l"]}', 'list a file' => '{error,enotdir}', 'list missing' => '{error,enoent}',
    'make dir' => 'ok', 'made dir' => DIRECTORY, 'make dir again' => '{error,eexist}',
    'make dir in missing' => '{error,enoent}', 'make dir dot' => '{error,eexist}',
    'make dir missing dotdot' => '{error,enoent}', 'make dir root' => '{error,eexist}',
    'del dir full' => '{error,eexist}', 'del dir dot' => '{error,einval}',
    'del dir missing dot' => '{error,enoent}', 'del dir file dot' => '{error,enotdir}',
    'del dir dotdot' => '{error,eexist}', 'del dir root' => '{error,ebusy}', 'del dir file' => '{error,enotdir}',
    'del dir' => 'ok', 'del dir gone' => '{error,enoent}',
    'delete file dot' => '{error,enotdir}', 'delete dir dot' => '{error,eperm}', 'delete dir' => '{error,eperm}',
    'delete root' => '{error,ebusy}', 'symlink' => 'ok', 'symlink made' => '{ok,"f"}',
    'delete victim' => '{error,enoent}', 'victim kept' => '{ok,"f"}', 'delete link' => 'ok',
    'link deleted' => '{error,enoent}', 'symlink dot' => '{error,eexist}',
    'symlink missing dotdot' => '{error,enoent}', 'symlink root' => '{error,eexist}',
    'rename' => 'ok', 'renamed' => "{{error,enoent},#{DIRECTORY}}", 'rename missing' => '{error,enoent}',
    'rename from dot' => '{error,ebusy}', 'rename to dot' => '{error,ebusy}',
    'rename missing dot' => '{error,enoent}', 'rename root' => '{error,ebusy}',
    'link' => 'ok', 'linked' => "{#{FILE},#{FILE}}", 'link dot' => '{error,eexist}',
    'link missing to dot' => '{error,enoent}', 'link missing' => '{error,enoent}',
    'link a directory' => '{error,eperm}', 'link root' => '{error,eexist}',
    'write info read' => 'ok', 'write mode' => 'ok', 'written mode' => CHANGED,
    'write bad mode' => '{error,badarg}', 'write missing' => '{error,enoent}',
    'ro info' => CHANGED, 'ro make dir' => '{error,erofs}', 'ro del dir' => '{error,erofs}',
    'ro delete' => '{error,erofs}', 'ro rename' => '{error,erofs}', 'ro link' => '{error,erofs}',
    'ro symlink' => '{error,erofs}', 'ro write info' => '{error,erofs}', 'ro kept' => "{#{CHANGED},#{DIRECTORY}}",
    'exdev rename' => '{error,exdev}', 'exdev link' => '{error,exdev}', 'fids held' => '0',
'slash info file' => '{error,enotdir}', 'slash info dir' => DIRECTORY, 'slash link info' => DIRECTORY,
'slash link info of a file' => '{error,enotdir}', 'slash read link' => '{error,einval}',
'slash list file' => '{error,enotdir}', 'slash write info' => '{error,enotdir}',
'slash delete file' => '{error,enotdir}', 'slash delete missing' => '{error,enoent}',
'slash delete dir' => '{error,eperm}', 'slash delete link' => '{error,enotdir}',
'slash kept' => "{#{FILE},#{LINK}}", 'slash make dir' => 'ok', 'slash made dir' => DIRECTORY,
'slash del dir file' => '{error,enotdir}', 'slash del dir link' => '{error,enotdir}',
'slash rename file' => '{error,enotdir}', 'slash rename to' => '{error,enotdir}',
'slash rename missing' => '{error,enoent}', 'slash rename dir' => 'ok',
'slash renamed dir' => "{{error,enoent},#{DIRECTORY}}", 'slash del dir' => 'ok',
'slash symlink new' => '{error,enoent}', 'slash symlink existing' => '{error,eexist}',
'slash hard link new' => '{error,enoent}', 'slash hard link existing' => '{error,enotdir}',
'slash nothing made' => '{{error,enoent},{error,enoent}}', 'slash fids held' => '0',
'link relative' => DIRECTORY, 'link relative through' => FILE, 'link relative list' => '{ok,["b","f"]}',
'link absolute' => FILE, 'link absolute read' => '{ok,"/s/a/f"}', 'link info' => LINK,
'link in a bind' => FILE, 'link above a bind' => "{#{FILE},{error,enoent}}",
'link to the release' => 'true', 'link to the release list' => 'true', 'link out exdev' => '{error,exdev}',
'link dangling' => "{{error,enoent},{ok,symlink,none,#{0o120777}}}", 'link empty' => '{error,enoent}',
'link loop' => '{{error,eloop},{error,eloop},{error,eloop}}', 'link forty' => FILE,
'link forty one' => '{error,eloop}', 'link make dir through' => "{ok,#{DIRECTORY}}",
'link rename through' => "{ok,#{DIRECTORY}}", 'link del dir through' => 'ok',
'link delete through' => '{ok,ok,{error,enoent}}', 'link delete not followed' => "{ok,ok,#{FILE}}",
'link hard link not followed' => '{ok,{ok,"a"}}', 'link ro relative' => '{error,erofs}',
'link ro absolute' => 'ok', 'link ro absolute written' => "{ok,regular,0,read_write,#{0o100600}}",
'link ro delete' => '{error,erofs}', 'link fids held' => '0',
    'link ro to writable' => "{ok,#{DIRECTORY},ok,{error,enoent}}", 'link sixteenth name' => "{ok,regular,0,read_write,#{0o100600}}",
    'hostile junk' => '{error,eio}', 'hostile bad qid' => '{error,eio}', 'hostile improper qids' => '{error,eio}',
    'hostile long walk' => '{error,eio}', 'hostile attr' => '{error,eio}', 'hostile dies' => '{error,eio}', 'hostile listing' => '{error,eio}',
    'hostile endless links' => '{error,eloop}', 'hostile bad link' => '{error,eio}',
    'hostile link attr' => '{error,eio}', 'hostile link attr info' => "{ok,symlink,none,#{0o120644}}"
  }.freeze

  # erx_file_remote's open files (design-files.md, Erlang clients, and Open files and
  # offsets), through file's descriptors: stock's answers for each mode and refusal, the
  # offset rule, a write past a cap, writes split into requests of 64 KiB, a server that
  # names no At, a grant that ended, and a call from a process that did not open the file.
  OPEN_FILES = {
    'open write' => '{ok,{ok,5}}', 'read through a write fd' => '{error,ebadf}',
    'close' => '{ok,{error,einval},{error,einval}}', 'read file' => '{ok,<<"hello">>}',
    'read' => '{{ok,<<"hel">>},{ok,<<"lo">>},eof,{ok,<<>>}}',
    'pread' => '{{ok,<<"el">>},{ok,[<<"h">>,eof]},{error,einval},{ok,5}}',
    'position' => '{{ok,3},{ok,<<"lo">>},{error,einval},{ok,0},{error,badarg}}',
    'write through a read fd' => '{{error,ebadf},{error,ebadf}}', 'truncate through a read fd' => '{error,einval}',
    'info of an open file' => "{ok,regular,5,read_write,#{0o100644}}",
    'not on controlling process' => '{raised,not_on_controlling_process}',
    'pwrite' => '{ok,{ok,0},ok,{ok,<<"HELlo!">>}}', 'truncate' => '{{ok,4},ok,{ok,<<"HELl">>}}',
    'sync' => '{ok,ok,ok,{error,enotsup}}',
    'write file' => '{ok,[<<"one\n">>,<<"two\n">>,<<"three">>]}', 'write file truncates' => '{ok,{ok,<<"x">>}}',
    'pread none' => '{eof,{error,badarg},{ok,[eof]}}',
    'open to write a directory' => '{{error,einval},{ok,<<"x">>}}',
    'open missing' => '{error,enoent}', 'open a directory' => '{error,eisdir}', 'open a directory as one' => 'ok',
    'open through a link' => 'ok', 'open exclusive existing' => '{error,eexist}', 'open exclusive new' => 'ok',
    'open exclusive a link' => '{error,eexist}', 'create in missing' => '{error,enoent}',
    'create slashed' => '{error,eisdir}', 'create a directory' => '{error,eisdir}', 'create the root' => '{error,eisdir}',
    'ro open read' => 'ok', 'ro open write' => '{error,erofs}', 'ro create' => '{error,erofs}',
    'ro create in missing' => '{error,enoent}', 'ro exclusive' => '{error,eexist}',
    'ro truncate' => '{{error,einval},{error,ebadf}}', 'ro unchanged' => '{ok,<<"x">>}', 'io server' => '{{ok,"x"},ok}',
    'appends' => '{[{97,1000},{98,1000}],2000}',
    'past the cap' => '{{error,enospc},{ok,65536},{error,enospc},65536}', 'split' => '{ok,3,true}',
    'unknown at' => '{{ok,ok,{ok,5}},{ok,{ok,100}}}',
    'grant gone' => '{{error,eio},{error,eio},{error,eio},{error,eio}}'
  }.freeze

  def test_erx_file_remote_answers_as_the_design_states
    release = table(@fixture.release)
    wrong = REMOTE.merge(OPEN_FILES).filter_map do |step, want|
      got = release.fetch("remote #{step}", 'missing')
      "#{step}: want #{want}, got #{got}" unless got == want
    end
    assert_empty wrong, wrong.join("\n")
  end

  # Seeded: a client whose walks act on their fid in place deletes /t/victim for
  # /t/missing/victim, which the victim case must catch.
  def test_seeded_walk_in_place_removes_the_victim
    seeded, lines = seeded_run('walk')
    assert_equal '{error,enoent}', seeded.fetch('seeded victim', 'missing'), lines.last(20).join("\n")
  end

  # Seeded: a client that sets an append's offset from a getattr's size, which the
  # appends case catches as a byte of the other appender's before the offset; one that
  # leaves the offset where it was on an error, which the write past the cap catches; one
  # that reads an append's unknown At as a plain fid's, which the fake server catches.
  def test_seeded_offset_faults_are_caught
    { 'append' => 'appends', 'cap' => 'past the cap', 'unknown' => 'unknown at' }.each do |seed, step|
      seeded, lines = seeded_run(seed)
      got = seeded.fetch("seeded #{step}", 'missing')
      refute_includes ['missing', OPEN_FILES.fetch(step)], got, "#{seed}: #{lines.last(20).join("\n")}"
    end
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

  # Its diagnostic and its end, with no spin (design-runtime.md, Verification).
  def test_a_release_with_no_boot_script_ends_with_inits_diagnostic
    archive = File.join(@fixture.directory, 'no-boot.pack')
    pack(@fixture.tree, archive, File.join(@fixture.directory, 'no-boot'), except: 'bin/start.boot')
    output, status = run_beam(archive, '/', 'release', boot: '/bin/start')
    refute status.success?, output.last(20).join("\n")
    assert_equal 1, status.exitstatus, output.last(20).join("\n")
    assert(output.any? { |line| line.include?('cannot get bootfile') }, output.last(20).join("\n"))
  end

  # The index stays intact, so only the manifest's own hash can see this.
  def test_a_changed_manifest_byte_is_refused_before_it_is_read
    changed = File.join(@fixture.directory, 'changed.pack')
    bytes = File.binread(@fixture.archive)
    at = bytes.index("/bin/start\0".b)
    bytes[at, 10] = '/bin/stbrt'.b
    File.binwrite(changed, bytes)
    output, status = run_beam(changed, '/', 'release', boot: '/bin/start')
    assert_equal 1, status.exitstatus, output.last(20).join("\n")
    assert(output.any? { |line| line.include?('boot archive refused:') }, output.last(20).join("\n"))
    refute(output.any? { |line| line.include?('bootfile') }, output.last(20).join("\n"))
  end

  private

  # A path over 64 bytes appears on its line as its MD5.
  def seeded_run(seed)
    lines, = run_beam(@fixture.archive, '/', 'seeded', seed, boot: '/bin/start')
    [table(lines), lines]
  end

  def line_key(operation, path)
    bytes = path.b
    "#{operation} #{(bytes.bytesize > 64 ? Digest::MD5.digest(bytes) : bytes).unpack1('H*')}"
  end

  def assert_refused(transcript, path, reason)
    OPERATIONS.each do |operation|
      answer = transcript.fetch(line_key(operation, path))
      want = operation == 'set_cwd' ? "{{error,#{reason}},<<\"ROOT/corpus\">>}" : "{error,#{reason}}"
      assert_equal want, answer, "#{operation} #{path.inspect}"
    end
  end

  # What the pins above answer for; every other line must agree with stock.
  def named?(key)
    _operation, hexadecimal = key.split(' ', 2)
    named = LEXICAL.keys + LIMITS.keys + [NOT_UTF8]
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
    # Whatever the umask: what the release's fixed modes are compared with.
    Dir.glob('**/*', base: tree).sort.reverse_each do |path|
      File.chmod(File.directory?(File.join(tree, path)) ? 0o555 : 0o444, File.join(tree, path))
    end
    File.chmod(0o555, tree)
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
    File.binwrite(File.join(tree, 'manifest'), Erx::Release.file_bytes(archive: OUTPUT.archive, path: 'system/manifest', codec: codec))
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

  def codec = (@codec ||= Erx::ABI::Codec.new(Erx::ABI::Generator.plan(root: ROOT).schema))

  # Stock OTP's emulator and its files, from the oracle build of the same release.
  def stock_beam
    install = File.dirname(File.dirname(Erx::Oracle.new(root: ROOT).erl_path(Erx::Runtime::HOST_OTP_FLAVOUR)))
    Dir.glob(File.join(install, '{lib/erlang/,}erts-*/bin/beam.smp')).first or flunk("no stock beam under #{install}")
  end

  # The driver, a grant over erx_fs_test_tree for erx_file_remote's cases, and the seeded
  # clients.
  GRANT_SOURCES = %w[erlang/apps/erx_files/src/erx_fs.erl erlang/apps/erx_files/src/erx_fs_grant.erl
                     erlang/apps/erx_files/src/erx_fs_version.erl
                     test/erlang/erx_fs_test_tree.erl].freeze
  CLIENT = 'otp/erts/preloaded/src/erx_file_remote.erl'
  # Each seeded client: the passage of the client it changes, once, and what it puts there.
  SEEDS = {
    'walk' => ["    {[{walk, From, New, NameList}], New};\n", "    _ = New,\n    {[{walk, From, From, NameList}], From};\n"],
    'append' => ["        {_, _} when is_integer(At) -> checked_offset(At + Count);\n",
                 "        {_, \#{append := false}} when is_integer(At) -> checked_offset(At + Count);\n" \
                 "        {_, \#{append := true}} -> size_of(File);\n"],
    'cap' => ["                    Moved(Next),\n", ''],
    'unknown' => ["        {unknown, \#{append := false}} -> checked_offset(Sent + Count);\n",
                  "        {unknown, _} -> checked_offset(Sent + Count);\n"]
  }.freeze

  # Seeded faults of design-tmp.md's Verification for /tmp. Each replaces passages of one
  # module; `mode` is the run it is loaded into: `tmp-seeded` runs the /tmp transcript and
  # `caught` lists the lines that must then differ from the unseeded run's, `cold` runs the
  # code-from-/tmp case and `caught` names what that run shows. A client seed is loaded
  # after boot (the client is preloaded); any other module is put first on the code path.
  TmpSeed = Data.define(:name, :source, :passages, :mode, :caught)
  CORE = 'erlang/apps/erx_files/src/erx_ramfs_core.erl'
  RAMFS = 'erlang/apps/erx_files/src/erx_ramfs.erl'
  GRANT = 'erlang/apps/erx_files/src/erx_fs_grant.erl'
  TMP_SEEDS = [
    TmpSeed.new(name: 'tmp-enotempty', source: CLIENT, mode: 'tmp-seeded', caught: ['tmp del dir full'],
                passages: [["        {error, Full} when Full =:= enotempty; Full =:= eexist -> working_directory_step(Path);\n",
                            "        {error, eexist} -> working_directory_step(Path);\n"]]),
    TmpSeed.new(name: 'tmp-dot-first', source: CLIENT, mode: 'tmp-seeded', caught: ['tmp del_dir missing/.'],
                passages: [["        true -> on_ok(directory(Rest), Special(Last));\n",
                            "        true -> Special(Last);\n"]]),
    TmpSeed.new(name: 'tmp-dot-text', source: CLIENT, mode: 'tmp-seeded',
                caught: ['tmp delete file/.', 'tmp file kept'],
                passages: [["special_name(<<\".\">>) -> true;\n", "special_name(<<\".\">>) -> false;\n"]]),
    TmpSeed.new(name: 'tmp-setattr-node', source: CORE, mode: 'tmp-seeded', caught: ['tmp truncate 0444'],
                passages: [["        {Ino, Access, _} = Handle,\n        {ok, Ino, N, {open, Access}}\n",
                            "        {Ino, _Access, _} = Handle,\n        {ok, Ino, N, node}\n"]]),
    TmpSeed.new(name: 'tmp-clunk-keeps-charge', source: CORE, mode: 'tmp-seeded',
                caught: ['tmpx held after close'],
                passages: [["            {done, ok, charged(-freed_charge(N1), release(Ino, N1, Tree))};\n",
                            "            {done, ok, release(Ino, N1, Tree)};\n"]]),
    TmpSeed.new(name: 'tmp-inode-counter-in-state', source: RAMFS, mode: 'tmp-seeded',
                caught: ['tmpx inode above'],
                passages: [["        {ok, Stamp} -> erx_ramfs_core:step(Request, Stamp, time_ns(), Tree);\n",
                            "        {ok, _} ->\n            Next = case get(counter) of undefined -> 1000000; C -> C + 1 end,\n" \
                            "            put(counter, Next),\n            erx_ramfs_core:step(Request, Next, time_ns(), Tree);\n"]]),
    TmpSeed.new(name: 'cold-unpreloaded-client-call', source: CLIENT, mode: 'cold', caught: ['halted'],
                passages: [["read_file(Grant, Place, Path) ->\n", "read_file(Grant, Place, Path) ->\n    _ = base64:encode(<<>>),\n"],
                           ["list_dir(Grant, Place, Path) ->\n", "list_dir(Grant, Place, Path) ->\n    _ = base64:encode(<<>>),\n"],
                           ["read_file_info(Grant, Place, FollowLinks, Path) ->\n",
                            "read_file_info(Grant, Place, FollowLinks, Path) ->\n    _ = base64:encode(<<>>),\n"]])
  ].freeze

  public

  # Each caught line must differ from the unseeded run's, which is the one design-tmp.md
  # and stock agree on, so the named line is what shows the fault.
  TMP_SEEDS.select { |seed| seed.mode == 'tmp-seeded' }.each do |seed|
    define_method(:"test_seeded_#{seed.name.tr('-', '_')}_is_caught") do
      transcript = table(seeded_tmp_run(seed))
      refute_empty transcript.keys.grep(/\Atmpx? /), "the /tmp transcript ran under #{seed.name}"
      seed.caught.each do |key|
        assert transcript.key?(key), "#{key} is in the seeded run under #{seed.name}"
        refute_equal table(@fixture.release).fetch(key), transcript.fetch(key), "#{seed.name} left #{key} as it was"
      end
    end
  end

  # The unseeded run of the cold case: a fresh runtime, every serving module loaded at
  # start, a missing module answered, a prepared beam loaded from /tmp and none of the
  # serving modules loaded by those steps.
  def test_code_from_tmp_in_a_cold_runtime
    output, status = cold_run('none')
    cold = table(output)
    assert_equal 0, status.exitstatus, output.last(20).join("\n")
    assert_equal({ 'cold serving missing at start' => '[]', 'cold missing' => '{error,nofile}',
                   'cold write' => 'ok', 'cold load' => '{module,tmp_cold}', 'cold call' => 'cold', 'cold serving loaded by it' => '[]' },
                 cold.slice(*%w[cold\ serving\ missing\ at\ start cold\ missing cold\ write cold\ load cold\ call
                                cold\ serving\ loaded\ by\ it]))
  end

  # A module erx_file_remote calls that is not preloaded: the code server, which is /tmp's
  # client, halts the node with the error handler's message.
  def test_seeded_cold_unpreloaded_client_call_is_caught
    output, status = cold_run('cold-unpreloaded-client-call')
    refute_equal 0, status.exitstatus, 'the node halted'
    assert_match(/called the unloaded module/, output.join("\n"))
    refute table(output).key?('cold call'), 'the case did not finish'
  end

  private

  def cold_run(seed)
    run_beam(@fixture.archive, '/', 'cold', seed, boot: '/bin/start', seed_dir: (seed == 'none' ? nil : seed))
  end

  def seeded_tmp_run(seed)
    output, status = run_beam(@fixture.archive, '/', 'tmp-seeded', seed.name, boot: '/bin/start', seed_dir: seed.name)
    assert_equal 0, status.exitstatus, output.last(20).join("\n")
    output
  end

  def compile_driver(tree)
    client = File.read(File.join(ROOT, CLIENT))
    includes = [File.join(ROOT, 'otp/lib/kernel/include'), File.join(ROOT, 'erlang/apps/erx/include')]
    erlc(GRANT_SOURCES.map { |source| File.join(ROOT, source) }, "#{tree}/test/ebin", includes)
    SEEDS.each do |name, (passage, fault)|
      assert_equal 1, client.scan(passage).size, "the #{name} seed's passage is in the client once"
      seeded = File.join(tree, 'test/seeded', name)
      FileUtils.mkdir_p(seeded)
      File.write(File.join(seeded, 'erx_file_remote.erl'), client.sub(passage, fault))
      erlc([File.join(seeded, 'erx_file_remote.erl')], seeded, includes)
      File.delete(File.join(seeded, 'erx_file_remote.erl'))
    end
    TMP_SEEDS.each { |seed| compile_tmp_seed(tree, seed, includes) }
    cold = File.join(tree, 'test/cold')
    FileUtils.mkdir_p(cold)
    File.write(File.join(cold, 'tmp_cold.erl'), "-module(tmp_cold).\n-export([f/0]).\nf() -> cold.\n")
    erlc([File.join(cold, 'tmp_cold.erl')], cold, [])
    File.delete(File.join(cold, 'tmp_cold.erl'))
    source = File.expand_path('prim_file_compare.erl', __dir__)
    expression = "{ok,_}=compile:file(\"#{source}\",[{outdir,\"#{tree}/test/ebin\"},{i,\"#{OUTPUT.root}/lib\"}]),halt()."
    output, status = Open3.capture2e(Erx::Oracle::CLEAN_ERLANG_ENV, 'gtimeout', '-k', '10', RUN_SECONDS.to_s,
                                     Erx::Oracle.new(root: ROOT).erl_path(Erx::Runtime::HOST_OTP_FLAVOUR),
                                     '-noshell', '-eval', expression, stdin_data: '')
    assert status.success?, output
  end

  def compile_tmp_seed(tree, seed, includes)
    original = File.read(File.join(ROOT, seed.source))
    text = seed.passages.reduce(original) do |source, (passage, fault)|
      assert_equal 1, source.scan(passage).size, "the #{seed.name} seed's passage is in #{seed.source} once"
      source.sub(passage) { fault }
    end
    directory = File.join(tree, 'test/seeded', seed.name)
    FileUtils.mkdir_p(directory)
    path = File.join(directory, File.basename(seed.source))
    File.write(path, text)
    erlc([path], directory, includes)
    File.delete(path)
  end

  def erlc(sources, outdir, includes)
    erlc = File.join(File.dirname(Erx::Oracle.new(root: ROOT).erl_path(Erx::Runtime::HOST_OTP_FLAVOUR)), 'erlc')
    output, status = Open3.capture2e(Erx::Oracle::CLEAN_ERLANG_ENV, 'gtimeout', '-k', '10', '120', erlc,
                                     *includes.flat_map { |dir| ['-I', dir] }, '-o', outdir, *sources, stdin_data: '')
    assert status.success?, "erlc exit #{status.exitstatus} (124 is the deadline)\n#{output}"
  end

  def pack(tree, archive, directory, except: nil)
    FileUtils.mkdir_p(directory)
    runner = Erx::Runner.new(owner_root: directory, log_dir: File.join(directory, 'logs'))
    tools = Erx::PackTools.build(root: ROOT, owner_root: directory, directory: File.join(directory, 'tools'),
                                 runner: runner, compiler: ENV.fetch('ERX_CLANG', 'clang'))
    system = codec.member('entry_flags', 'system')
    files = Dir.glob('**/*', base: tree).select { |path| File.file?(File.join(tree, path)) && path != except }
    rows = files.sort.map do |path|
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

  def run_beam(archive, root, *arguments, boot:, seed_dir: nil)
    prefix = root == '/' ? '' : root
    erxos = Erx::ErlangApps::APPLICATIONS.flat_map { |application| ['-pa', "#{prefix}/lib/#{application}/ebin"] }
    erxos += ['-pa', "#{prefix}/test/seeded/#{seed_dir}"] if seed_dir
    test = ['-noshell', *erxos, '-pa', "#{prefix}/test/ebin", '-run', 'prim_file_compare', 'main', root, *arguments]
    return capture_beam({ 'ROOTDIR' => root, 'BINDIR' => File.dirname(OUTPUT.beam) }, [OUTPUT.beam, archive, *test]) if archive

    bin = File.dirname(stock_beam)
    # Stock's own kernel first: the tree's has erx_console in place of the terminal NIF stock's -noshell starts.
    test = ['-pa', Dir[File.join(bin, '../../lib/kernel-*/ebin')].fetch(0), *test]
    capture_beam({ 'ROOTDIR' => root, 'BINDIR' => bin },
                 [stock_beam, '--', '-root', root, '-bindir', bin, '-progname', 'erl', '--', '-home', '/', '--', '-boot', boot, *test])
  end

  # Output and exit status of a command with no shell, no terminal and no home.
  def capture_beam(extra_environment, command)
    environment = Erx::Oracle::CLEAN_ERLANG_ENV.merge(
      'EMU' => 'beam', 'PROGNAME' => 'erl', 'HOME' => nil, 'ERL_CRASH_DUMP_BYTES' => '0'
    ).merge(extra_environment)
    output, status = Timeout.timeout(RUN_SECONDS) do
      Open3.capture2e(environment, 'gtimeout', '-k', '10', RUN_SECONDS.to_s, *command, stdin_data: '', chdir: '/')
    end
    [output.lines(chomp: true), status]
  end
end
