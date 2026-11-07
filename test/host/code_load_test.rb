# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'minitest/autorun'
require 'tmpdir'
require_relative '../../tools/lib/erx/code_commands'
require_relative '../../tools/lib/erx/reload_guest'

# The tree, for erlc's include directories.
module Erx
  ROOT_FOR_TESTS = File.expand_path('../..', __dir__)
end

# A guest's install facet as a script: each call is checked against the next expected
# request and answered with its reply.
class ScriptedFacet
  attr_reader :calls

  def initialize(script)
    @script = script.dup
    @calls = []
  end

  def call(term, target: 0)
    @calls << [term, target]
    expected, reply = @script.shift
    raise "unexpected call #{term.inspect}" unless expected.nil? || expected == term

    reply
  end

  def done? = @script.empty?
end

class CodeLoadTest < Minitest::Test
  Etf = Erx::Etf
  CodeLoad = Erx::CodeLoad
  OK = Etf::Atom.new(name: 'ok')

  def tuple(*elements) = Etf::Tuple.new(elements: elements)
  def atom(name) = Etf::Atom.new(name: name)
  def blob(name, bytes) = CodeLoad::Blob.of(name: name, bytes: bytes)

  def test_a_blob_is_named_by_the_sha256_of_its_bytes
    module_blob = blob('mod', 'bytes')
    assert_equal Digest::SHA256.digest('bytes'), module_blob.sha256
    assert_equal Digest::SHA256.hexdigest('bytes'), module_blob.hex
  end

  def test_names_the_store_or_a_terminal_would_refuse_are_refused
    ["Mod", '', "a\e[2J", 'a b', "a'b", 'a' * 256, "a\u{e9}"].each do |name|
      assert_raises(Erx::Error, name) { blob(name, 'x') }
    end
    assert_raises(Erx::Error) { blob('mod', '') }
    assert blob("a#{'b' * 254}", 'x')
  end

  def test_a_file_names_its_module_by_its_base_name
    Dir.mktmpdir do |directory|
      path = File.join(directory, 'my_mod.beam')
      File.binwrite(path, "\x00\xffbeam")
      assert_equal 'my_mod', CodeLoad::Blob.from_file(path).name
      other = File.join(directory, 'my_mod.erl')
      File.write(other, 'x')
      assert_raises(Erx::Error) { CodeLoad::Blob.from_file(other) }
    end
  end

  def test_pieces_are_64_kib_but_the_last
    sizes = { 1 => [1], 65_536 => [65_536], 65_537 => [65_536, 1], 200_000 => [65_536, 65_536, 65_536, 3_392] }
    sizes.each do |size, expected|
      pieces = CodeLoad.pieces(blob('m', 'z' * size))
      assert_equal expected, pieces.map { |_offset, bytes| bytes.bytesize }
      assert_equal (0...expected.size).map { |index| index * 65_536 }, pieces.map(&:first)
      assert_equal 'z' * size, pieces.map(&:last).join
    end
  end

  def test_the_facet_opens_as_a_host_cap
    facet = ScriptedFacet.new([[CodeLoad::OPEN_INSTALL, tuple(OK, tuple(atom('$host_cap'), 3))]])
    assert_equal 3, CodeLoad.open_install(facet)
    refused = ScriptedFacet.new([[nil, tuple(atom('error'), atom('noproc'))]])
    error = assert_raises(CodeLoad::Refused) { CodeLoad.open_install(refused) }
    assert_match(/\{error,noproc\}/, error.message)
  end

  # Only the blobs the store lacks are sent, each in its pieces, before the one load.
  def test_install_sends_only_what_the_store_lacks
    held = blob('held', 'h' * 10)
    large = blob('large', 'l' * 70_000)
    facet = ScriptedFacet.new(
      [[CodeLoad.missing_request([held, large]), tuple(OK, [large.sha256])],
       [CodeLoad.put_request(large, 0, 'l' * 65_536), tuple(OK, tuple(atom('next'), 65_536))],
       [CodeLoad.put_request(large, 65_536, 'l' * 4_464), tuple(OK, atom('stored'))],
       [CodeLoad.load_request([held, large]), OK]]
    )
    result = CodeLoad.install(facet, facet: 7, blobs: [held, large])
    assert facet.done?
    assert_equal ['large'], result.sent
    assert_equal %w[held large], result.loaded
    assert(facet.calls.all? { |_term, target| target == 7 })
    manifest = facet.calls.last.first.elements.last
    assert_equal [tuple('held', held.sha256), tuple('large', large.sha256)], manifest
  end

  def test_nothing_is_sent_when_the_store_holds_everything
    held = blob('held', 'h')
    facet = ScriptedFacet.new([[nil, tuple(OK, [])], [CodeLoad.load_request([held]), OK]])
    assert_empty CodeLoad.install(facet, facet: 1, blobs: [held]).sent
  end

  # The guest's replies are untrusted: one outside the code service's answers is refused,
  # and its text reaches the error only through the line escape.
  def test_refusals_show_the_guest_reply_escaped
    mod = blob('mod', 'm')
    cases = [
      [[nil, tuple(OK, [Digest::SHA256.digest('other')])]],
      [[nil, tuple(OK, [mod.sha256])], [nil, tuple(atom('error'), atom('hash_mismatch'))]],
      [[nil, tuple(OK, [mod.sha256])], [nil, tuple(OK, tuple(atom('next'), 1))]],
      [[nil, tuple(OK, [])], [nil, tuple(atom('error'), tuple(atom('not_loaded'), [tuple("m\e]0;x\a", atom('badfile'))]))]]
    ]
    cases.each do |script|
      error = assert_raises(CodeLoad::Refused) { CodeLoad.install(ScriptedFacet.new(script), facet: 1, blobs: [mod]) }
      refute_match(/[\x00-\x1f\x7f]/, error.message)
    end
  end

  def test_a_batch_names_each_module_once
    assert_raises(Erx::Error) { CodeLoad.install(ScriptedFacet.new([]), facet: 1, blobs: [blob('a', 'x'), blob('a', 'y')]) }
    assert_raises(Erx::Error) { CodeLoad.install(ScriptedFacet.new([]), facet: 1, blobs: []) }
  end
end

class CodeWatchTest < Minitest::Test
  Scan = Erx::CodeWatch::Scan
  Stamp = Erx::CodeWatch::Stamp

  def test_changed_sources_are_new_or_restamped
    time = Time.at(0)
    before = { 'a.erl' => Stamp.new(mtime: time, size: 1), 'b.erl' => Stamp.new(mtime: time, size: 1) }
    after = { 'a.erl' => Stamp.new(mtime: time, size: 1), 'b.erl' => Stamp.new(mtime: time + 1, size: 1),
              'c.erl' => Stamp.new(mtime: time, size: 2) }
    assert_equal %w[b.erl c.erl], Scan.changed(before, after)
    assert_empty Scan.changed(after, after.slice('a.erl'))
  end

  # A watch takes the sources as they stand, then compiles and loads each change as one
  # batch; a failed compile is reported, the watch goes on, and the sources of the failed
  # round stay pending until a load of them succeeds.
  def test_a_watch_loads_what_changed
    Dir.mktmpdir do |directory|
      File.write(File.join(directory, 'a.erl'), 'a')
      FileUtils.mkdir_p(File.join(directory, 'sub'))
      lines = []
      loads = []
      round = 0
      edits = [
        -> { File.write(File.join(directory, 'sub/b.erl'), 'b') },
        -> { File.write(File.join(directory, 'a.erl'), 'a changed') },
        lambda {
          File.write(File.join(directory, 'a.erl'), 'a again')
          File.write(File.join(directory, 'bad.erl'), 'bad')
        },
        -> {},
        -> { File.write(File.join(directory, 'bad.erl'), 'fixed') }
      ]
      compile = lambda do |source, output:|
        raise Erx::Error, "erlc #{source} failed:\nline one\nline two" if File.read(source) == 'bad'

        File.join(output, "#{File.basename(source, '.erl')}.beam")
      end
      watch = Erx::CodeWatch.new(compile: compile, load: ->(beams) { loads << beams.map { |path| File.basename(path) } && 'loaded' },
                                 out: ->(line) { lines << line }, sleep: ->(_seconds) { edits.fetch(round).call.then { round += 1 } })
      watch.call(directory, rounds: 5)
      assert_equal [['b.beam'], ['a.beam'], %w[a.beam bad.beam]], loads
      assert_includes lines, 'line two'
      assert_equal "watching 1 sources under #{directory}", lines.first
    end
  end

  def test_a_scan_leaves_out_a_dangling_link
    Dir.mktmpdir do |directory|
      File.write(File.join(directory, 'a.erl'), 'a')
      File.symlink(File.join(directory, 'gone'), File.join(directory, 'b.erl'))
      assert_equal [File.join(directory, 'a.erl')], Scan.call(directory).keys
    end
  end
end

# A Runner that records what it was asked to run and answers with result.
class RecordingRunner
  attr_reader :runs

  def initialize(failure: nil)
    @failure = failure
    @runs = []
  end

  def run(argv, **options)
    @runs << [argv, options]
    raise Erx::CommandError, @failure if @failure

    {}
  end
end

class ErlangCompileTest < Minitest::Test
  # erlc runs as an argument vector with the image's includes, a deadline and OTP's clean
  # environment.
  def test_erlc_runs_like_the_image_build
    runner = RecordingRunner.new
    compile = Erx::ErlangCompile.new(erlc: '/oracle/erlc', root: Erx::ROOT_FOR_TESTS, runner: runner)
    assert_equal '/out/m.beam', compile.call('src/m.erl', output: '/out')
    argv, options = runner.runs.first
    assert_equal ['/oracle/erlc', '+deterministic', '+debug_info'], argv.first(3)
    assert_includes argv.each_cons(2).to_a, ['-I', 'erlang/apps/erx/include']
    assert_equal ['-o', '/out', File.expand_path('src/m.erl')], argv.last(3)
    assert_equal Erx::Oracle::CLEAN_ERLANG_ENV, options[:env]
    assert options[:deadline].positive?
  end

  def test_a_failed_compile_reports_erlc_output
    Dir.mktmpdir do |directory|
      log = File.join(directory, 'erlc.log')
      File.write(log, "m.erl:3: syntax error\n")
      runner = RecordingRunner.new(failure: { 'state' => 'failed', 'log' => log })
      compile = Erx::ErlangCompile.new(erlc: '/oracle/erlc', root: Erx::ROOT_FOR_TESTS, runner: runner)
      error = assert_raises(Erx::Error) { compile.call('m.erl', output: directory) }
      assert_match(/m\.erl:3: syntax error/, error.message)
    end
  end
end

class CodeCommandsTest < Minitest::Test
  Commands = Erx::CodeCommands

  def test_a_socket_that_cannot_be_reached_is_an_erx_error
    Dir.mktmpdir do |directory|
      target = Commands::Target.new(socket: File.join(directory, 'none.sock'), build: nil)
      assert_raises(Erx::Error) { Commands.connect_socket(target) { flunk } }
    end
  end

  def run_load(arguments, connect: ->(_target) { raise 'no connection expected' })
    Commands.load(arguments, connect: connect, compile: ->(*) { raise 'no compile expected' }, out: ->(_line) {})
  end

  def test_options_are_checked_before_anything_connects
    assert_raises(OptionParser::InvalidArgument) { run_load(['m.beam']) }
    assert_raises(OptionParser::InvalidArgument) { run_load(%w[--socket /s]) }
    assert_raises(OptionParser::InvalidArgument) { run_load(%w[--socket /s --domain 5 m.beam]) }
    assert_raises(OptionParser::InvalidArgument) { run_load(%w[--socket /s --build xyz m.beam]) }
  end

  def test_load_sends_the_files_as_one_batch
    Dir.mktmpdir do |directory|
      paths = %w[a b].map { |name| File.join(directory, "#{name}.beam").tap { |path| File.binwrite(path, name) } }
      targets = []
      facet = ScriptedFacet.new([[Erx::CodeLoad::OPEN_INSTALL, Erx::Etf::Tuple.new(elements: [Erx::CodeLoad::OK,
                                  Erx::Etf::Tuple.new(elements: [Erx::CodeLoad::HOST_CAP, 1])])],
                                 [nil, Erx::Etf::Tuple.new(elements: [Erx::CodeLoad::OK, []])],
                                 [nil, Erx::CodeLoad::OK]])
      connect = lambda do |target, &block|
        targets << target
        block.call(facet)
      end
      lines = []
      status = Commands.load(['--socket', '/s', '--build', 'AB12', *paths], connect: connect, compile: nil, out: ->(line) { lines << line })
      assert_equal 0, status
      assert_equal [Commands::Target.new(socket: '/s', build: 'ab12')], targets
      assert_equal ['loaded a b (sent 0 of 2 modules)'], lines
    end
  end
end

class ReloadGuestTest < Minitest::Test
  Guest = Erx::ReloadGuest

  # The start expression travels as one word of the kernel command line.
  def test_the_start_expression_is_one_word
    refute_match(/[\s'"]/, Guest::START)
  end

  def test_the_verdict_holds_only_without_stale_calls
    line = 'reload-probe done committed 33 stale 0 behind 0 calls 5,6,7,8 straddled 3 killed 0 tags 33,30,33,2'
    result = Guest.verdict(Guest::DONE.match(line), cpus: 4, loads: 32)
    assert_equal 26, result[:calls]
    stale = line.sub('stale 0', 'stale 1')
    assert_raises(Erx::Error) { Guest.verdict(Guest::DONE.match(stale), cpus: 4, loads: 32) }
    behind = line.sub('behind 0', 'behind 2')
    assert_raises(Erx::Error) { Guest.verdict(Guest::DONE.match(behind), cpus: 4, loads: 32) }
    idle = line.sub('5,6,7,8', '5,0,7,8')
    assert_raises(Erx::Error) { Guest.verdict(Guest::DONE.match(idle), cpus: 4, loads: 32) }
    short = line.sub('committed 33', 'committed 32')
    assert_raises(Erx::Error) { Guest.verdict(Guest::DONE.match(short), cpus: 4, loads: 32) }
    one_tag = line.sub('tags 33,30,33,2', 'tags 33,30,33,1')
    assert_raises(Erx::Error) { Guest.verdict(Guest::DONE.match(one_tag), cpus: 4, loads: 32) }
  end

  def test_a_failed_probe_line_ends_the_wait_escaped
    Dir.mktmpdir do |directory|
      serial = File.join(directory, 'serial.log')
      File.binwrite(serial, "debug reload-probe failed worker \e[31mred\r\n")
      error = assert_raises(Erx::Error) { Guest.wait_for(serial, Guest::DONE, seconds: 5) }
      assert_match(/failed worker/, error.message)
      refute_match(/\e/, error.message)
    end
  end

  def test_subject_versions_return_their_tag
    assert_includes Guest.subject_source(7), 'tag() -> 7.'
  end
end
