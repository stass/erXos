# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'digest'
require 'fileutils'
require 'json'
require 'minitest/autorun'
require 'open3'
require 'rbconfig'
require 'tmpdir'
require_relative '../../tools/lib/erx/generated'

# The build tree of generated files: its stamp, its lock, and the
# properties the real generators must keep (they load no generated file and
# their output depends only on their inputs).
class GeneratedTest < Minitest::Test
  ROOT = File.expand_path('../..', __dir__).freeze
  LIBRARY = File.join(ROOT, 'tools/lib/erx/generated.rb').freeze
  FAKE_CODE = { 'tools/lib/erx/fake.rb' => '0' * 64 }.freeze

  def setup
    @directory = Dir.mktmpdir('erx-generated-')
    @root = File.join(@directory, 'root')
    @output = File.join(@directory, 'build/gen')
    @calls = File.join(@directory, 'calls')
    FileUtils.mkdir_p(File.join(@root, 'in'))
    File.binwrite(File.join(@root, 'in/a.txt'), 'alpha')
    File.binwrite(File.join(@root, 'in/one.def'), '')
  end

  def teardown
    FileUtils.rm_rf(@directory)
  end

  # A generator over @root/in: a.txt is read, *.def files are discovered.
  def fake(code: FAKE_CODE, delay: 0, name: 'fake', extra: {})
    calls = @calls
    plan = lambda do |root|
      File.open(calls, 'a') { |file| file.write('x') }
      sleep(delay)
      bytes = File.binread(File.join(root, 'in/a.txt'))
      matches = Dir.glob('in/*.def', base: root).sort
      Erx::GenerationPlan.new(files: { 'out/a.h' => "/* #{bytes} */\n", 'out/list.txt' => "#{matches.join(' ')}\n" }
                                       .merge(extra),
                              reads: { 'in/a.txt' => Digest::SHA256.hexdigest(bytes) },
                              globs: { 'in/*.def' => matches })
    end
    Erx::Generated::Generator.new(name: name, plan: plan, code: code)
  end

  def static(name, files, reads: {})
    Erx::Generated::Generator.new(name: name, code: {},
                                  plan: ->(_root) { Erx::GenerationPlan.new(files: files, reads: reads) })
  end

  def ensure_tree(generators = [fake]) = Erx::Generated.ensure(root: @root, output: @output, generators: generators)

  def calls = File.exist?(@calls) ? File.size(@calls) : 0

  def output(relative) = File.binread(File.join(@output, relative))

  def test_second_ensure_with_unchanged_inputs_writes_nothing
    assert_equal :generated, ensure_tree.status
    inode = File.stat(File.join(@output, 'out/a.h')).ino
    result = ensure_tree
    assert_equal :fresh, result.status
    assert_equal File.realpath(@output), File.realpath(result.output)
    assert_equal 1, calls
    assert_equal inode, File.stat(File.join(@output, 'out/a.h')).ino
    assert_equal "/* alpha */\n", output('out/a.h')
  end

  def test_an_edited_input_regenerates
    ensure_tree
    File.binwrite(File.join(@root, 'in/a.txt'), 'beta')
    assert_equal :generated, ensure_tree.status
    assert_equal "/* beta */\n", output('out/a.h')
    assert_equal :fresh, ensure_tree.status
  end

  def test_a_new_or_removed_glob_match_regenerates
    ensure_tree
    File.binwrite(File.join(@root, 'in/two.def'), '')
    assert_equal :generated, ensure_tree.status
    assert_equal "in/one.def in/two.def\n", output('out/list.txt')
    File.unlink(File.join(@root, 'in/one.def'))
    assert_equal :generated, ensure_tree.status
    assert_equal "in/two.def\n", output('out/list.txt')
  end

  def test_changed_generator_code_regenerates
    ensure_tree
    assert_equal :generated, ensure_tree([fake(code: { 'tools/lib/erx/fake.rb' => '1' * 64 })]).status
    assert_equal :generated, ensure_tree([fake, static('other', { 'out/b.h' => "b\n" })]).status
  end

  def test_a_tree_that_differs_from_its_stamp_regenerates
    damage = {
      'removed output' => -> { File.unlink(File.join(@output, 'out/a.h')) },
      'edited output' => -> { File.binwrite(File.join(@output, 'out/a.h'), "/* edited */\n") },
      'stray file' => -> { File.binwrite(File.join(@output, 'out/stale.h'), "stale\n") },
      'link in the tree' => -> { File.symlink('a.h', File.join(@output, 'out/link.h')) },
      'malformed stamp' => -> { File.binwrite(File.join(@output, '.stamp.json'), '{') },
      'stamp of another version' => lambda do
        path = File.join(@output, '.stamp.json')
        File.binwrite(path, JSON.generate(JSON.parse(File.binread(path)).merge('version' => 0)))
      end,
      'stamp naming a path outside the root' => lambda do
        path = File.join(@output, '.stamp.json')
        document = JSON.parse(File.binread(path))
        document['reads']['../escape'] = '0' * 64
        File.binwrite(path, JSON.generate(document))
      end,
      'empty stray directory' => -> { Dir.mkdir(File.join(@output, 'stale')) },
      'stamp of another toolchain' => lambda do
        path = File.join(@output, '.stamp.json')
        File.binwrite(path, JSON.generate(JSON.parse(File.binread(path)).merge('toolchain' => { 'ruby' => '0' })))
      end,
      'stamp with a brace glob' => lambda do
        path = File.join(@output, '.stamp.json')
        document = JSON.parse(File.binread(path))
        document['globs'] = { '{..,in}/*' => [] }
        File.binwrite(path, JSON.generate(document))
      end
    }
    damage.each do |label, action|
      ensure_tree
      action.call
      assert_equal :generated, ensure_tree.status, label
      assert_equal "/* alpha */\n", output('out/a.h'), label
      assert_equal :fresh, ensure_tree.status, label
    end
  end

  def test_unchanged_outputs_keep_their_modification_time
    ensure_tree
    past = Time.at(1_000_000_000)
    File.utime(past, past, File.join(@output, 'out/list.txt'))
    File.utime(past, past, File.join(@output, 'out/a.h'))
    File.binwrite(File.join(@root, 'in/a.txt'), 'gamma')
    assert_equal :generated, ensure_tree.status
    assert_equal past, File.mtime(File.join(@output, 'out/list.txt'))
    refute_equal past, File.mtime(File.join(@output, 'out/a.h'))
  end

  def test_a_failing_generator_leaves_the_previous_tree
    ensure_tree
    File.binwrite(File.join(@root, 'in/a.txt'), 'refused')
    failing = Erx::Generated::Generator.new(name: 'fake', code: FAKE_CODE,
                                            plan: ->(_root) { raise Erx::Error, 'input refused' })
    error = assert_raises(Erx::Error) { ensure_tree([failing]) }
    assert_equal 'input refused', error.message
    assert_equal "/* alpha */\n", output('out/a.h')
    assert_equal ['gen', 'gen.lock'], Dir.children(File.dirname(@output)).sort
    assert_equal :generated, ensure_tree.status
  end

  def test_a_failing_write_leaves_the_previous_tree
    ensure_tree
    File.binwrite(File.join(@root, 'in/a.txt'), 'beta')
    # Sorted after out/a.h and out/list.txt, so the write fails part way
    # through the staging tree: the file name is longer than any file system
    # accepts.
    unwritable = fake(extra: { "out/z#{'a' * 300}.h" => "x\n" })
    error = assert_raises(Erx::Generated::Error) { ensure_tree([unwritable]) }
    assert_match(/name too long/i, error.message)
    assert_equal "/* alpha */\n", output('out/a.h')
    assert_equal ['gen', 'gen.lock'], Dir.children(File.dirname(@output)).sort
  end

  def test_leftovers_of_a_killed_run_are_removed
    ensure_tree
    FileUtils.mkdir_p("#{@output}.old-backup")
    FileUtils.mkdir_p("#{@output}.stage-1-0123abcd/out")
    FileUtils.mkdir_p("#{@output}.old-1-0123abcd")
    assert_equal :fresh, ensure_tree.status
    assert_equal ['gen', 'gen.lock', 'gen.old-backup'], Dir.children(File.dirname(@output)).sort
  end

  def test_malformed_plans_are_refused_before_anything_is_written
    plans = {
      'repeated name' => [static('one', { 'a' => "a\n" }), static('one', { 'b' => "b\n" })],
      'input path the stamp cannot hold' => [static('bad', { 'a' => "a\n" }, reads: { 'in/a b.txt' => '1' * 64 })],
      'not ASCII' => [static('bad', { 'out/a.h' => "caf\u00e9\n" })],
      'climbing path' => [static('bad', { '../a.h' => "a\n" })],
      'absolute path' => [static('bad', { '/tmp/a.h' => "a\n" })],
      'dot component' => [static('bad', { 'out/./a.h' => "a\n" })],
      'stamp path' => [static('bad', { '.stamp.json' => "{}\n" })],
      'output claimed twice' => [static('one', { 'out/a.h' => "a\n" }), static('two', { 'out/a.h' => "a\n" })],
      'file and directory' => [static('one', { 'out' => "a\n" }), static('two', { 'out/a.h' => "a\n" })],
      'disagreeing inputs' => [static('one', { 'a' => "a\n" }, reads: { 'in/a.txt' => '1' * 64 }),
                               static('two', { 'b' => "b\n" }, reads: { 'in/a.txt' => '2' * 64 })],
      'climbing glob' => [Erx::Generated::Generator.new(
        name: 'bad', code: {},
        plan: ->(_root) { Erx::GenerationPlan.new(files: { 'a' => "a\n" }, reads: {}, globs: { '../*' => [] }) }
      )],
      'brace glob' => [Erx::Generated::Generator.new(
        name: 'bad', code: {},
        plan: ->(_root) { Erx::GenerationPlan.new(files: { 'a' => "a\n" }, reads: {}, globs: { '{..,in}/*' => [] }) }
      )]
    }
    plans.each do |label, generators|
      assert_raises(Erx::Generated::Error, label) { ensure_tree(generators) }
      refute File.exist?(@output), label
    end
  end

  def test_only_a_generated_tree_is_ever_replaced
    ensure_tree
    File.unlink(File.join(@output, '.stamp.json'))
    error = assert_raises(Erx::Generated::Error) { ensure_tree }
    assert_match(/not a generated tree/, error.message)
    assert File.file?(File.join(@output, 'out/a.h'))
    keep = File.join(@root, 'keep.c')
    File.binwrite(keep, "int x;\n")
    [@root, File.dirname(@root)].each do |output|
      assert_raises(Erx::Generated::Error, output) do
        Erx::Generated.ensure(root: @root, output: output, generators: [fake])
      end
    end
    sibling = File.join(@directory, 'sources')
    FileUtils.mkdir_p(sibling)
    File.binwrite(File.join(sibling, 'keep.c'), "int y;\n")
    assert_raises(Erx::Generated::Error) { Erx::Generated.ensure(root: @root, output: sibling, generators: [fake]) }
    assert File.file?(keep)
    assert File.file?(File.join(sibling, 'keep.c'))
  end

  def test_concurrent_ensure_calls_build_one_complete_tree
    readers = 2.times.map do
      reader, writer = IO.pipe
      pid = fork do
        reader.close
        writer.write(ensure_tree([fake(delay: 0.5)]).status.to_s)
        writer.close
        exit!(0)
      end
      writer.close
      [pid, reader]
    end
    statuses = readers.map do |pid, reader|
      Process.wait(pid)
      assert_predicate $?, :success?
      reader.read.tap { reader.close }
    end
    assert_equal %w[fresh generated], statuses.sort
    assert_equal 1, calls
    assert_equal :fresh, ensure_tree.status
  end

  def test_path_mirrors_repository_paths
    assert_equal File.join(@root, 'build/gen/include/erx/abi.h'),
                 Erx::Generated.path('include/erx/abi.h', root: @root)
    ['../x', '/x', 'a//b', 'a/../b', '', "a\nb"].each do |relative|
      assert_raises(Erx::Generated::Error, relative) { Erx::Generated.path(relative, root: @root) }
    end
  end

  # The generators must build from a tree that has no generated file yet,
  # so none of them may load one: the bootstrap invariant.
  def test_generator_libraries_load_no_generated_file
    script = <<~RUBY
      require ARGV.fetch(0)
      outputs = Erx::Generated::GENERATORS.flat_map { |generator| generator.plan.call(ARGV.fetch(1)).files.keys }
      puts JSON.generate('features' => $LOADED_FEATURES, 'outputs' => outputs)
    RUBY
    report = JSON.parse(ruby(script, LIBRARY, ROOT))
    outputs = report.fetch('outputs').map { |relative| File.join(ROOT, relative) }
    refute_empty outputs
    loaded = report.fetch('features').map { |path| File.expand_path(path) }
    assert_empty loaded & outputs
    assert_empty(loaded.grep(%r{\A#{Regexp.escape(ROOT)}/(?:build|tools/generated)/}))
  end

  # The stamp's code record covers what each library loads, at require time
  # and while it plans, so an edit to any file a generator runs regenerates
  # the tree.
  def test_code_record_covers_what_each_generator_loads_and_runs
    {
      'abi' => ['tools/lib/erx/abi.rb', 'Erx::ABI::Generator'], 'hardware' => ['tools/lib/erx/hardware.rb', 'Erx::Hardware'],
      'terminal' => ['tools/lib/erx/terminal_generation.rb', 'Erx::TerminalRules']
    }.each do |name, (library, owner)|
      script = "before = $LOADED_FEATURES.dup\nrequire ARGV.fetch(0)\n" \
               "Object.const_get(ARGV.fetch(1)).generation(root: ARGV.fetch(2))\n" \
               "puts(($LOADED_FEATURES - before).join(\"\n\"))\n"
      loaded = ruby(script, File.join(ROOT, library), owner, ROOT).lines.map(&:chomp)
                                                    .select { |path| path.start_with?("#{ROOT}/") }
                                                    .map { |path| path.delete_prefix("#{ROOT}/") }
      generator = Erx::Generated::GENERATORS.find { |candidate| candidate.name == name }
      refute_empty loaded, name
      assert_empty loaded - generator.code.keys, name
    end
  end

  # Generation depends only on its inputs: two runs from different working
  # directories, at different times and in different time zones, into
  # differently named output roots, give byte-identical trees.
  def test_generation_is_deterministic
    script = "require ARGV.fetch(0)\nErx::Generated.ensure(root: ARGV.fetch(1), output: ARGV.fetch(2))\n"
    trees = [%w[first UTC], %w[second-tree Asia/Kathmandu]].map do |name, zone|
      output = File.join(@directory, name, 'out')
      FileUtils.mkdir_p(File.join(@directory, name, 'cwd'))
      ruby(script, LIBRARY, ROOT, output, env: { 'TZ' => zone }, chdir: File.join(@directory, name, 'cwd'))
      Dir.glob('**/*', File::FNM_DOTMATCH, base: output).sort
         .select { |relative| File.file?(File.join(output, relative)) }
         .to_h { |relative| [relative, File.binread(File.join(output, relative))] }
    end
    assert_includes trees.first.keys, '.stamp.json'
    assert_equal trees.first, trees.last
  end

  # While the tracked copies exist they are what the drift checks pin, so
  # the build tree must hold the same bytes.
  def test_real_tree_matches_the_tracked_outputs_and_is_then_fresh
    output = File.join(@directory, 'real/gen')
    assert_equal :generated, Erx::Generated.ensure(root: ROOT, output: output).status
    files = Dir.glob('**/*', base: output).select { |relative| File.file?(File.join(output, relative)) }
    assert_operator files.size, :>=, 30
    files.each do |relative|
      assert_equal File.binread(File.join(ROOT, relative)), File.binread(File.join(output, relative)), relative
    end
    assert_equal :fresh, Erx::Generated.ensure(root: ROOT, output: output).status
  end

  private

  def ruby(script, *arguments, env: {}, chdir: ROOT)
    stdout, stderr, status = Open3.capture3(env, RbConfig.ruby, '-rjson', '-e', script, *arguments,
                                            chdir: chdir, stdin_data: '')
    assert_predicate status, :success?, stderr
    stdout
  end
end
