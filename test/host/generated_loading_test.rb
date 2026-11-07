# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'fileutils'
require 'minitest/autorun'
require 'open3'
require 'rbconfig'
require 'tmpdir'
require_relative '../../tools/lib/erx/generated'

# How the tools' Ruby loads generated Ruby files, checked from the source:
#
# * the generators load no generated file, directly or through a loader, at
#   require time or lazily, so generation never depends on its own earlier
#   output (the bootstrap invariant);
# * everything else loads a generated Ruby file only through a loader
#   (tools/lib/erx/generated_*.rb), whose one call to
#   Erx::Generated.require_ruby makes the build tree fresh and loads the
#   file from build/gen, never a copy beside the sources.
#
# The check reads loads written as a statement of their own line, as the
# tree writes them; `Kernel.require` or a load after a semicolon is not
# seen, and outside the generators a computed load is suspect only when
# its own text names generated files, so `load file` with file computed on
# an earlier line is not either. GeneratedTest checks the first property at run time as well, by
# what the generators actually load; this check also sees loads on paths
# the real inputs do not take, and names the chain that reaches the
# offending file.
class GeneratedLoadingTest < Minitest::Test
  ROOT = File.expand_path('../..', __dir__).freeze
  # The library that runs every generator; the generator scripts
  # (tools/gen_*.rb) are found by name.
  GENERATOR_LIBRARY = 'tools/lib/erx/generated.rb'
  # A require, require_relative or load at the start of a line, with its
  # argument: a string literal, or for an argument computed at run time
  # whatever follows (not an assignment to a variable of that name).
  LOAD = /^\s*(?<kind>require_relative|require|load)(?:\s+|\s*\(\s*)
          (?:(?<quote>['"])(?<literal>[^'"]+)\k<quote>|(?<computed>[^\s=].*))/x
  LOADER_CALL = /\bGenerated\.require_ruby\b/
  LOADER = %r{\Atools/lib/erx/generated_[a-z_]+\.rb\z}
  # The one load computed at run time that the generators reach:
  # Erx::Generated.require_ruby's own `require file`, which no generator
  # calls.
  COMPUTED_LOADS = [[GENERATOR_LIBRARY, 'file']].freeze
  # Where generated files live: the build tree, and tools/generated, the
  # path a generated Ruby file mirrors there, which a stray load would name.
  # A computed load is suspect when its text names generated files at all.
  GENERATED = %r{\A(?:tools/generated|build)/}
  NAMES_GENERATED = /generated/

  # One load a file makes. kind is :file (target: a repository-relative
  # path), :gem (target: a library outside the tree), :computed (target:
  # the argument's text) or :loader (a call of Erx::Generated.require_ruby,
  # target: nil).
  Load = Data.define(:kind, :target)

  def setup
    @directory = Dir.mktmpdir('erx-generated-loading-')
  end

  def teardown
    FileUtils.rm_rf(@directory)
  end

  def test_generators_load_no_generated_file
    assert_empty generator_violations(ROOT)
    COMPUTED_LOADS.each do |path, text|
      assert_includes loads(ROOT, path), Load.new(kind: :computed, target: text),
                      "#{path} no longer loads `#{text}`: update COMPUTED_LOADS"
    end
  end

  # A loader takes the build tree's lock around a file that loads nothing
  # more, so nothing nested inside it takes the lock again.
  def test_generated_ruby_loads_nothing
    output = Erx::Generated.ensure(root: ROOT).output
    files = Dir.glob('tools/generated/*.rb', base: output)
    refute_empty files
    files.each { |relative| assert_empty File.read(File.join(output, relative)).scan(LOAD), relative }
  end

  def test_require_ruby_loads_only_generated_ruby
    %w[tools/lib/erx/abi.rb tools/generated/terminal_notices.json tools/generated/../lib/erx/abi.rb
       tools/generated/absent.rb].each do |path|
      assert_raises(Erx::Generated::Error, path) { Erx::Generated.require_ruby(path) }
    end
  end

  # The block runs while ensure still holds the lock.
  def test_ensure_runs_a_block_under_the_lock
    output = File.join(@directory, 'gen')
    held = nil
    result = ensure_one(output) do |inside|
      assert_equal :generated, inside.status
      held = File.open("#{output}.lock") { |lock| !lock.flock(File::LOCK_EX | File::LOCK_NB) }
    end
    assert held
    assert_equal :generated, result.status
    assert(File.open("#{output}.lock") { |lock| lock.flock(File::LOCK_EX | File::LOCK_NB) })
  end

  # A second ensure of the same tree inside the first would wait on the
  # process's own lock forever; it is refused, and the lock is released.
  def test_a_nested_ensure_is_refused
    output = File.join(@directory, 'gen')
    error = assert_raises(Erx::Generated::Error) { ensure_one(output) { ensure_one(output) } }
    assert_match(/called again while it is held/, error.message)
    assert_equal :fresh, ensure_one(output).status
  end

  # The process entries that ensure the tree (the test fixture, tools/erx)
  # and the loaders, which ensure it again and load under the lock, run in
  # one process in either order: each ensure returns before the next, so
  # none waits on the lock its own process holds. Each runs in a process of
  # its own under a deadline, so a wait shows as a failure, not a hang.
  def test_entries_and_loaders_ensure_one_after_another
    fixture = File.join(ROOT, 'test/fixtures/generated_tree.rb')
    loader = File.join(ROOT, 'tools/lib/erx/generated_abi.rb')
    [[fixture, loader], [loader, fixture]].each do |first, second|
      assert_runs(RbConfig.ruby, '-e', 'ARGV.each { |file| require file }', first, second)
    end
    assert_match(/^generated files in .*: up to date$/, assert_runs(RbConfig.ruby, File.join(ROOT, 'tools/erx'), 'generate'))
  end

  def test_a_generator_reaching_a_loader_is_caught
    plant('tools/lib/erx/abi_model.rb', "require_relative 'generated_abi'")
    assert_includes generator_violations(@directory),
                    'tools/lib/erx/generated_abi.rb loads a generated file through Erx::Generated.require_ruby ' \
                    '(reached by tools/lib/erx/generated.rb -> tools/lib/erx/abi.rb -> tools/lib/erx/abi_model.rb)'
  end

  def test_a_generator_loading_a_generated_copy_is_caught
    plant('tools/lib/erx/hardware.rb', "  require_relative '../../generated/abi'")
    assert_includes generator_violations(@directory),
                    'tools/lib/erx/hardware.rb loads tools/generated/abi.rb (reached by tools/lib/erx/generated.rb)'
  end

  def test_a_generator_load_computed_at_run_time_is_caught
    plant('tools/lib/erx/terminal_rules.rb', 'load File.join(root, "build/gen/x.rb")')
    assert_includes generator_violations(@directory),
                    'tools/lib/erx/terminal_rules.rb loads a path computed at run time, which this check cannot ' \
                    'follow: File.join(root, "build/gen/x.rb") ' \
                    '(reached by tools/lib/erx/generated.rb -> tools/lib/erx/terminal_generation.rb)'
  end

  def test_a_new_generator_script_is_checked
    plant('tools/gen_probe.rb', "require_relative 'lib/erx/generated_abi'", create: true)
    assert_includes generator_violations(@directory),
                    'tools/lib/erx/generated_abi.rb loads a generated file through Erx::Generated.require_ruby ' \
                    '(reached by tools/gen_probe.rb)'
  end

  def test_only_loaders_load_generated_ruby
    assert_empty bypasses(ROOT)
  end

  def test_a_consumer_bypassing_the_loaders_is_caught
    plant('test/fixtures/cap_model.rb', "require_relative '../../tools/generated/abi'", copy: [])
    assert_equal ['test/fixtures/cap_model.rb loads tools/generated/abi.rb'], bypasses(@directory)
  end

  def test_a_consumer_loading_a_computed_generated_path_is_caught
    plant('tools/lib/erx/boot_record.rb', "require File.expand_path('../../generated/abi', __dir__)", copy: [])
    assert_equal ["tools/lib/erx/boot_record.rb loads File.expand_path('../../generated/abi', __dir__)"],
                 bypasses(@directory)
  end

  def test_a_consumer_calling_require_ruby_itself_is_caught
    plant('test/fixtures/cap_model.rb', "Erx::Generated.require_ruby('tools/generated/abi.rb')", copy: [])
    assert_equal ['test/fixtures/cap_model.rb loads a generated file through Erx::Generated.require_ruby, ' \
                  'not through a loader'], bypasses(@directory)
  end

  def test_a_ruby_script_without_an_extension_is_checked
    plant('tools/probe', "#!/usr/bin/env ruby\nrequire_relative 'generated/abi'", copy: [], create: true)
    assert_equal ['tools/probe loads tools/generated/abi.rb'], bypasses(@directory)
  end

  private

  def assert_runs(*command)
    output, status = Open3.capture2e('gtimeout', '-k', '5', '120', *command, stdin_data: '', chdir: ROOT)
    assert status.success?, "#{command.join(' ')} ended with #{status.inspect}\n#{output}"
    output
  end

  # ensure of a one-file tree generated from an empty root into output.
  def ensure_one(output, &)
    root = File.join(@directory, 'root')
    FileUtils.mkdir_p(root)
    plan = Erx::GenerationPlan.new(files: { 'a.txt' => "a\n" }, reads: {})
    generator = Erx::Generated::Generator.new(name: 'one', code: {}, plan: ->(_root) { plan })
    Erx::Generated.ensure(root: root, output: output, generators: [generator], &)
  end

  # Every generated file the generators reach, with the chain of loads that
  # reaches it.
  def generator_violations(root)
    entries = Dir.glob('tools/gen_*.rb', base: root).sort + [GENERATOR_LIBRARY]
    reached = entries.to_h { |entry| [entry, [entry]] }
    queue = entries.dup
    violations = []
    until queue.empty?
      path = queue.shift
      before = reached.fetch(path)[0...-1]
      chain = before.empty? ? '' : " (reached by #{before.join(' -> ')})"
      loads(root, path).each do |found|
        case found
        in { kind: :loader }
          violations << "#{path} loads a generated file through Erx::Generated.require_ruby#{chain}"
        in { kind: :computed, target: text } if COMPUTED_LOADS.include?([path, text])
          nil
        in { kind: :computed, target: text }
          violations << "#{path} loads a path computed at run time, which this check cannot follow: #{text}#{chain}"
        in { kind: :file, target: GENERATED => relative }
          violations << "#{path} loads #{relative}#{chain}"
        in { kind: :file, target: relative } if !reached.key?(relative) && File.file?(File.join(root, relative))
          reached[relative] = reached.fetch(path) + [relative]
          queue << relative
        in { kind: :file | :gem }
          nil
        end
      end
    end
    violations
  end

  # Every Ruby file of the tools and tests that loads a generated file other
  # than through a loader: by a literal path, by a computed one that names
  # generated files, or by calling Erx::Generated.require_ruby itself.
  def bypasses(root)
    ruby_sources(root).reject { |path| path.match?(GENERATED) }.flat_map do |path|
      loads(root, path).filter_map do |found|
        case found
        in { kind: :file, target: GENERATED } | { kind: :computed, target: NAMES_GENERATED }
          "#{path} loads #{found.target}"
        # The loaders make the call; this file names it in its own tests.
        in { kind: :loader } unless path.match?(LOADER) || path == relative_to_root(__FILE__)
          "#{path} loads a generated file through Erx::Generated.require_ruby, not through a loader"
        else
          nil
        end
      end
    end
  end

  # The Ruby files beneath tools and test: *.rb, and scripts without an
  # extension whose first line runs ruby.
  def ruby_sources(root)
    scripts = Dir.glob('{tools,test}/**/*', base: root).select do |path|
      file = File.join(root, path)
      File.extname(path).empty? && File.file?(file) &&
        File.open(file, 'rb') { |io| io.read(128) }.to_s.match?(/\A#![^\n]*\bruby\b/n)
    end
    (Dir.glob('{tools,test}/**/*.rb', base: root) + scripts).sort
  end

  # What one file loads, in the order written, then a loader call if it
  # makes one.
  def loads(root, path)
    text = File.read(File.join(root, path))
    found = text.to_enum(:scan, LOAD).map do
      match = Regexp.last_match
      if match[:literal]
        resolve(root, path, kind: match[:kind], literal: match[:literal])
      else
        Load.new(kind: :computed, target: match[:computed].strip)
      end
    end
    text.match?(LOADER_CALL) ? found + [Load.new(kind: :loader, target: nil)] : found
  end

  # A literal path, resolved as the tree uses each form: require_relative
  # beside the file, and require or load beneath tools/lib, the one
  # directory the tools put on the load path. The .rb a require adds is
  # added to a load too; the tree loads only Ruby files. A require that
  # names no file of the tree is a library outside it.
  def resolve(root, path, kind:, literal:)
    base = kind == 'require_relative' ? File.dirname(File.join(root, path)) : File.join(root, 'tools/lib')
    absolute = File.expand_path(literal, base)
    absolute += '.rb' unless File.extname(absolute) == '.rb'
    if kind == 'require' && !File.file?(absolute) && !literal.start_with?('/')
      return Load.new(kind: :gem, target: literal)
    end

    Load.new(kind: :file, target: absolute.delete_prefix("#{root}/"))
  end

  def relative_to_root(file) = File.expand_path(file).delete_prefix("#{ROOT}/")

  # A copy of the given files and directories (by default what the
  # generators run) with one line added to one file, created if asked.
  def plant(path, line, copy: Dir.glob('tools/gen_*.rb', base: ROOT) + %w[tools/lib], create: false)
    (create ? copy : copy + [path]).uniq.each do |relative|
      FileUtils.mkdir_p(File.dirname(File.join(@directory, relative)))
      FileUtils.cp_r(File.join(ROOT, relative), File.join(@directory, relative))
    end
    target = File.join(@directory, path)
    FileUtils.mkdir_p(File.dirname(target))
    File.write(target, "#{create ? '' : File.read(target)}#{line}\n")
  end
end
