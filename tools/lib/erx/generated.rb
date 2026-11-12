# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'digest'
require 'fileutils'
require 'json'
require 'securerandom'
require_relative 'error'
require_relative 'generation_plan'
require_relative 'json_input'
require_relative 'abi'
require_relative 'hardware'
require_relative 'facet_names'
require_relative 'terminal_generation'

module Erx
  # The build tree's generated files. Every generator's plan is published
  # into one output root, build/gen/, which mirrors repository-relative
  # paths, so an include of "liberx/generated/calls.h" or "erx/abi.h" finds
  # the generated file through -I build/gen and -I build/gen/include.
  #
  # The tree carries a stamp (STAMP, at its top) naming what it was computed
  # from: the digest of every input file each generator read, the expansion
  # of every glob a generator discovered inputs with, the digest of every
  # Ruby file beneath tools/lib of the running code with the Ruby and library
  # versions it runs on, and the digest of every output. The tree is fresh
  # exactly when all of these still hold and it holds nothing else;
  # otherwise ensure regenerates all of it, which takes well under a second.
  #
  # Concurrency: ensure holds an exclusive flock on a lock file beside the
  # tree for its whole check and publish, so parallel callers serialize and
  # all but the first find the tree fresh. A new tree is written into a
  # staging directory beside the output and moved into place by directory
  # rename, so no caller of ensure sees a partial tree. A reader that does
  # not hold the lock, such as a compiler, can see the tree missing for the
  # moment between the two renames of a regeneration, or read files of the
  # old tree and of the new one in one pass; regeneration happens only when
  # the stamp fails (TODO.md records the residual). Files
  # whose bytes did not change keep their modification time,
  # so make-style consumers rebuild only against outputs that changed.
  #
  # ensure replaces only a directory that is empty or carries a stamp, so it
  # deletes nothing it did not write. Generators reach this module only
  # through GenerationPlan; adding an output to a generator's plan needs no
  # change here.
  #
  # Who calls ensure: every process entry, before anything reads build/gen
  # (tools/erx before it loads its libraries; in a test process
  # test/fixtures/generated_tree.rb or an ensure at the top of the test file;
  # a standalone script in its main block). require_ruby calls it as well,
  # because a loader runs at require time and loads under the lock. Any other
  # ensure in a library is a guard that finds the tree fresh, not part of the
  # contract; a fresh tree is checked in milliseconds.
  module Generated
    class Error < Erx::Error; end

    OUTPUT = 'build/gen'
    STAMP = '.stamp.json'
    STAMP_VERSION = 1
    MAX_STAMP_BYTES = 4 * 1024 * 1024
    STAMP_KEYS = %w[code generators globs outputs reads toolchain version].freeze
    # The repository whose generator code is running, which may differ from
    # the root a caller generates from (tests generate from temporary roots).
    CODE_ROOT = File.expand_path('../../..', __dir__)
    PATH = %r{\A[A-Za-z0-9_][A-Za-z0-9_.-]*(?:/[A-Za-z0-9_][A-Za-z0-9_.-]*)*\z}
    # A glob relative to the source root: no braces, which can name a path
    # outside it, and no escapes.
    PATTERN = %r{\A[A-Za-z0-9_*?\[\]][A-Za-z0-9_.*?\[\]-]*(?:/[A-Za-z0-9_*?\[\]][A-Za-z0-9_.*?\[\]-]*)*\z}
    DIGEST = /\A[0-9a-f]{64}\z/
    LEFTOVER = /\A(?:stage|old)-\d+-[0-9a-f]{8}\z/

    # Every Ruby file of the running tools library, hashed when this file
    # loads, so the stamp names the code that is running. Wider than any one
    # generator's closure, but it cannot miss a file a generator loads.
    CODE = Dir.glob('tools/lib/**/*.rb', base: CODE_ROOT).sort.to_h do |relative|
      [relative, Digest::SHA256.file(File.join(CODE_ROOT, relative)).hexdigest]
    end.freeze
    # What the code runs on and what can change the bytes it writes: the
    # Ruby release and the versions of the json and rexml gems loaded, or
    # "unknown" where one was loaded without RubyGems.
    TOOLCHAIN = %w[json rexml].to_h { |name| [name, Gem.loaded_specs[name]&.version&.to_s || 'unknown'] }
                              .merge('ruby' => RUBY_VERSION).sort.to_h.freeze

    # name: for diagnostics and the stamp. plan: callable taking the source
    # root and returning a GenerationPlan. code: repository-relative Ruby
    # path => SHA-256 of the code the plan runs.
    Generator = Data.define(:name, :plan, :code)

    # What a tree holds and what it was computed from; see the module
    # comment. Each field is a sorted, frozen Hash, except generators, a
    # sorted Array of names.
    Stamp = Data.define(:generators, :code, :toolchain, :reads, :globs, :outputs) do
      def to_bytes
        JSON.pretty_generate({ 'version' => STAMP_VERSION, 'generators' => generators, 'code' => code,
                               'toolchain' => toolchain, 'reads' => reads, 'globs' => globs,
                               'outputs' => outputs }) + "\n"
      end
    end

    # status is :fresh (nothing written) or :generated; output is the
    # absolute output root.
    Result = Data.define(:status, :output)

    GENERATORS = [
      Generator.new(name: 'abi', plan: ->(root) { ABI::Generator.generation(root: root) }, code: CODE),
      Generator.new(name: 'hardware', plan: ->(root) { Hardware.generation(root: root) }, code: CODE),
      Generator.new(name: 'terminal', plan: ->(root) { TerminalRules.generation(root: root) }, code: CODE),
      Generator.new(name: 'facets', plan: ->(root) { FacetNames.generation(root: root) }, code: CODE)
    ].freeze

    class << self
      # The absolute path of one generated file beneath root's output tree.
      # Pure: callers that read the file call ensure first.
      def path(relative, root:) = File.join(File.expand_path(root), OUTPUT, checked_path(relative))

      # The C compiler's include flags for root's generated tree, which go
      # ahead of the tree's own -I . and -I include: the output root resolves
      # an include of "liberx/generated/calls.h" and its include directory
      # one of "erx/abi.h". Pure, like path.
      def include_flags(root:) = ['-I', File.join(File.expand_path(root), OUTPUT), '-I', path('include', root: root)]

      # Makes output (by default root/build/gen) hold exactly what the
      # generators compute from root, regenerating only when the stamp
      # fails, so no caller can have a fresh tree replaced. Safe to call
      # from many processes at once. A block runs with the result while the
      # lock is still held, so another caller's regeneration cannot move the
      # tree away while it reads. root's own tree (no output given) is
      # refused while a file of root sits at the path of one of its files
      # (refuse_shadowing). A system error of ensure's own file operations
      # becomes an Error naming the tree, one of a generator an Error naming
      # the generator (plan), and one of the block reaches the caller as it is.
      def ensure(root:, output: nil, generators: GENERATORS)
        own = output.nil?
        source = filesystem(output || root) { File.realpath(root) }
        output = filesystem(output || root) { resolved(output || File.join(source, OUTPUT)) }
        if source == output || source.start_with?(File.join(output, ''))
          raise Error, "generated output #{output} would hold its own source root"
        end

        with_lock(output) do
          result = filesystem(output) { bring_up_to_date(output, root: source, generators: generators, own: own) }
          yield result if block_given?
          result
        end
      end

      # The files, relative to the tree, in which root's own build/gen and a
      # tree generated into scratch, an empty directory of the caller's
      # choosing, differ in bytes or presence. scratch is generated first,
      # then build/gen is brought up to date and read under its lock. How
      # check-reproducible shows that the tree is a function of its inputs
      # without replacing the tree other builds read.
      def regeneration_differences(root:, scratch:, generators: GENERATORS)
        unless !File.exist?(scratch) || (File.directory?(scratch) && Dir.empty?(scratch))
          raise Error, "#{scratch} is not an empty directory to generate into"
        end

        digests = ->(tree) { filesystem(tree.output) { tree_digests(tree.output) } }
        regenerated = digests.call(self.ensure(root: root, output: scratch, generators: generators))
        built = nil
        self.ensure(root: root, generators: generators) { |tree| built = digests.call(tree) }
        (regenerated.keys | built.keys).sort.reject { |relative| regenerated[relative] == built[relative] }
      end

      # Generates the files of the one generator named into output, a
      # directory of the caller's choosing that is empty or an earlier such
      # tree: what tools/gen_abi.rb, gen_hw.rb and gen_terminal.rb run, to
      # read one generator's files outside a build. Any other directory is
      # refused, root's own build/gen among them, since ensure replaces what
      # it writes into whole.
      def generate_one(name, root:, output:)
        generator = GENERATORS.find { |candidate| candidate.name == name }
        raise Error, "no generator is named #{name}" unless generator

        output = resolved(output)
        if output == resolved(File.join(root, OUTPUT))
          raise Error, "#{output} is the build's generated tree, which holds every generator's files"
        end
        unless !File.exist?(output) || (File.directory?(output) && Dir.empty?(output)) ||
               read_stamp(output)&.generators == [name]
          raise Error, "#{output} is neither empty nor an earlier output of the #{name} generator"
        end

        self.ensure(root: root, output: output, generators: [generator])
      rescue SystemCallError => error
        raise Error, "cannot generate the #{name} files into #{output}: #{error.message}"
      end

      # Loads one generated Ruby file (a path of tools/generated/) from the
      # build tree of the repository whose code is running, after making that
      # tree fresh, and under its lock. The one way the tools' own Ruby loads
      # a generated file: each loader beside this file (generated_abi.rb and
      # the like) loads what the generated file uses, then calls this once;
      # no generator may reach a loader (test/host/generated_loading_test.rb).
      # The generated file itself loads nothing, so nothing nested here takes
      # the lock again.
      def require_ruby(relative)
        unless relative.start_with?('tools/generated/') && relative.end_with?('.rb')
          raise Error, "#{relative} is not a generated Ruby file"
        end

        checked_path(relative)
        self.ensure(root: CODE_ROOT) do |result|
          file = File.join(result.output, relative)
          raise Error, "#{relative} is not in the generated tree #{result.output}" unless File.file?(file)

          require file
        end
      end

      private

      # ensure's work under the lock: leftovers of a killed run go, and the
      # tree is checked against its stamp and published again if it fails.
      def bring_up_to_date(output, root:, generators:, own:)
        remove_leftovers(output)
        result = if fresh?(output, root: root, generators: generators)
                   Result.new(status: :fresh, output: output)
                 else
                   plans = generators.map { |generator| [generator.name, plan(generator, root: root)] }
                   publish(output, files: combine(plans, generators: generators))
                   Result.new(status: :generated, output: output)
                 end
        refuse_shadowing(root, output) if own
        result
      end

      # Pure: every plan's files plus the stamp, refused whole if any output
      # path is malformed, claimed twice or not ASCII, if two generators
      # disagree about an input they both read, or if the stamp would not
      # read back.
      def combine(plans, generators:)
        names = plans.map(&:first)
        raise Error, 'generator names repeat' unless names.uniq == names

        files = {}
        reads = {}
        globs = {}
        plans.each do |name, plan|
          raise Error, "generator #{name} returned no GenerationPlan" unless plan.is_a?(GenerationPlan)

          plan.files.each do |relative, bytes|
            checked_path(relative)
            raise Error, "generated output #{relative} is claimed twice" if files.key?(relative)
            raise Error, "generated output #{relative} is not ASCII" unless bytes.is_a?(String) && bytes.ascii_only?

            files[relative] = bytes
          end
          merge_agreeing(reads, plan.reads, what: 'input digest')
          merge_agreeing(globs, plan.globs, what: 'glob expansion')
        end
        directories = files.keys.flat_map { |relative| parents(relative) }
        clash = files.keys.find { |relative| directories.include?(relative) }
        raise Error, "generated output #{clash} is also a directory" if clash

        stamp = Stamp.new(generators: names.sort, code: code_digests(generators), toolchain: TOOLCHAIN,
                          reads: reads.sort.to_h, globs: globs.sort.to_h,
                          outputs: files.sort.to_h { |relative, bytes| [relative, Digest::SHA256.hexdigest(bytes)] })
        bytes = stamp.to_bytes
        unless stamp_shape?(stamp) && bytes.ascii_only? && bytes.bytesize <= MAX_STAMP_BYTES
          raise Error, 'generated tree stamp would not read back: an input path, glob or digest is malformed'
        end

        files.merge(STAMP => bytes).sort.to_h.freeze
      end

      # No file of root sits at the path of a file of its generated tree: the
      # generated file is the only copy, so no include path, glob, merge or
      # copy of any consumer can take a stale one in its place. Checked on
      # every ensure, fresh or not, so it holds for every process that reads
      # the tree.
      def refuse_shadowing(root, output)
        stamp = read_stamp(output)
        raise Error, "generated tree #{output} has no readable #{STAMP}" unless stamp

        shadowing = stamp.outputs.keys.select do |relative|
          File.exist?(File.join(root, relative)) || File.symlink?(File.join(root, relative))
        end
        return if shadowing.empty?

        raise Error, "these files are at the paths of generated files, which the build generates into " \
                     "#{OUTPUT}; remove them: #{shadowing.first(8).join(', ')}"
      end

      # Whether output holds exactly the tree its stamp describes and every
      # recorded input, glob and code digest still holds against root.
      def fresh?(output, root:, generators:)
        stamp = read_stamp(output)
        return false unless stamp && stamp.generators == generators.map(&:name).sort &&
                            stamp.code == code_digests(generators) && stamp.toolchain == TOOLCHAIN
        return false unless stamp.globs.all? { |pattern, paths| Dir.glob(pattern, base: root).sort == paths }
        return false unless stamp.reads.all? { |relative, digest| input_digest(File.join(root, relative)) == digest }

        tree_matches?(output, stamp)
      end

      # The tree holds the stamp, the recorded outputs with their recorded
      # bytes and the directories they need, and nothing else.
      def tree_matches?(output, stamp)
        files, directories = tree_entries(output)
        return false unless files

        files.sort == (stamp.outputs.keys + [STAMP]).sort &&
          directories.sort == stamp.outputs.keys.flat_map { |relative| parents(relative) }.uniq.sort &&
          stamp.outputs.all? { |relative, digest| output_digest(File.join(output, relative)) == digest }
      end

      # An unreadable or malformed stamp is nil, never an error: the tree is
      # a cache and is rebuilt. A JSON library that cannot read safely is a
      # host fault and propagates.
      def read_stamp(output)
        bytes = read_regular(File.join(output, STAMP), maximum: MAX_STAMP_BYTES, follow: false)
        return nil unless bytes

        document = JsonInput.parse(bytes, max_bytes: MAX_STAMP_BYTES, label: 'generated tree stamp')
        return nil unless document.is_a?(Hash) && document.keys.sort == STAMP_KEYS &&
                          document['version'] == STAMP_VERSION

        stamp = Stamp.new(**document.except('version').transform_keys(&:to_sym))
        stamp_shape?(stamp) ? stamp : nil
      rescue JsonInput::Unsupported
        raise
      rescue Erx::Error, SystemCallError
        nil
      end

      def stamp_shape?(stamp)
        digest_table = lambda do |table|
          table.is_a?(Hash) && table.all? { |relative, digest| path?(relative) && digest.is_a?(String) && DIGEST.match?(digest) }
        end
        [stamp.code, stamp.reads, stamp.outputs].all?(&digest_table) &&
          stamp.generators.is_a?(Array) && stamp.generators.all?(String) &&
          stamp.toolchain.is_a?(Hash) && stamp.toolchain.all? { |key, value| [key, value].all?(String) } &&
          stamp.globs.is_a?(Hash) && stamp.globs.all? do |pattern, paths|
            pattern?(pattern) && paths.is_a?(Array) && paths.all? { |relative| path?(relative) }
          end
      end

      # The regular files and directories beneath output, relative to it;
      # nil if output is not a directory or holds anything else (a link, a
      # device), which makes the tree not fresh.
      def tree_entries(output)
        return nil unless File.lstat(output).directory?

        entries = Dir.glob('**/*', File::FNM_DOTMATCH, base: output).reject { |entry| File.basename(entry) == '.' }
        kinds = entries.group_by { |entry| File.lstat(File.join(output, entry)).ftype }
        return nil unless (kinds.keys - %w[file directory]).empty?

        [kinds.fetch('file', []), kinds.fetch('directory', [])]
      rescue SystemCallError
        nil
      end

      # A source input may be reached through a link, as the generators
      # reach it; an output may not.
      def input_digest(path) = file_digest(path, follow: true)

      def output_digest(path) = file_digest(path, follow: false)

      # Streamed in chunks: a path named by a stamp may be any size.
      def file_digest(path, follow:)
        open_regular(path, follow: follow) do |file|
          digest = Digest::SHA256.new
          while (chunk = file.read(1 << 20))
            digest.update(chunk)
          end
          digest.hexdigest
        end
      end

      # The bytes of a regular file, or nil if it is missing, is not a
      # regular file, or exceeds maximum.
      def read_regular(path, maximum:, follow:)
        open_regular(path, follow: follow) do |file|
          next nil if file.stat.size > maximum

          bytes = file.read(maximum + 1) || ''.b
          bytes.bytesize <= maximum ? bytes : nil
        end
      end

      # Yields path opened for reading if it is a regular file, and returns
      # the block's value; nil otherwise. Opened without blocking and checked
      # on the open descriptor, so a FIFO swapped in cannot hang the lock
      # holder.
      def open_regular(path, follow:)
        flags = File::RDONLY | File::NONBLOCK
        flags |= File::NOFOLLOW unless follow
        File.open(path, flags) { |file| file.stat.file? ? yield(file) : nil }
      rescue SystemCallError
        nil
      end

      # Writes files into a fresh staging directory beside output, then moves
      # it into place. A failure before the move leaves the old tree as it was.
      def publish(output, files:)
        refuse_foreign(output)
        staging = "#{output}.stage-#{Process.pid}-#{SecureRandom.hex(4)}"
        Dir.mkdir(staging, 0o755)
        files.each do |relative, bytes|
          target = File.join(staging, relative)
          FileUtils.mkdir_p(File.dirname(target))
          File.open(target, File::WRONLY | File::CREAT | File::EXCL, 0o644) { |file| file.write(bytes) }
          keep_time(target, previous: File.join(output, relative), bytes: bytes)
        end
        swap(staging, output)
      ensure
        FileUtils.rm_rf(staging) if staging && File.directory?(staging)
      end

      # Only a directory this module wrote is ever replaced: one that is
      # empty or carries a stamp file, whatever its contents.
      def refuse_foreign(output)
        return unless File.exist?(output) || File.symlink?(output)
        raise Error, "generated output #{output} is not a directory" unless File.lstat(output).directory?

        stamp = File.join(output, STAMP)
        return if Dir.empty?(output) || (File.exist?(stamp) && File.lstat(stamp).file?)

        raise Error, "refusing to replace #{output}: it holds no #{STAMP}, so it is not a generated tree; remove it to regenerate"
      end

      # An unchanged file keeps the modification time it had in the old tree.
      def keep_time(target, previous:, bytes:)
        return unless read_regular(previous, maximum: bytes.bytesize, follow: false) == bytes

        old = File.lstat(previous)
        File.utime(old.atime, old.mtime, target)
      end

      def swap(staging, output)
        unless File.exist?(output)
          File.rename(staging, output)
          return
        end
        retired = "#{output}.old-#{Process.pid}-#{SecureRandom.hex(4)}"
        File.rename(output, retired)
        begin
          File.rename(staging, output)
        rescue SystemCallError
          File.rename(retired, output)
          raise
        end
        FileUtils.rm_rf(retired)
      end

      # Staging and retired trees a killed run left behind, named exactly as
      # publish and swap name them. Called with the lock held, so none of
      # them belongs to a live run.
      def remove_leftovers(output)
        parent = File.dirname(output)
        prefix = "#{File.basename(output)}."
        Dir.children(parent).each do |name|
          next unless name.start_with?(prefix) && LEFTOVER.match?(name.delete_prefix(prefix))

          path = File.join(parent, name)
          FileUtils.rm_rf(path) if File.lstat(path).directory?
        end
      end

      # The lock is per open file, so a second ensure of the same output on
      # this thread (any fiber), from a generator or from a file a block
      # loads, would wait on its own lock forever; it is refused instead.
      # Held locks are named by the lock file's real path, so another
      # spelling of the same tree is the same lock.
      def with_lock(output)
        lock_path = filesystem(output) do
          FileUtils.mkdir_p(File.dirname(output))
          File.join(File.realpath(File.dirname(output)), "#{File.basename(output)}.lock")
        end
        held = Thread.current.thread_variable_get(:erx_generated_locks) ||
               Thread.current.thread_variable_set(:erx_generated_locks, [])
        if held.include?(lock_path)
          raise Error, "ensure of #{output} called again while it is held: " \
                       'a generator or a generated file loads a generated file'
        end

        lock = filesystem(output) { File.open(lock_path, File::RDWR | File::CREAT, 0o644) }
        begin
          filesystem(output) { lock.flock(File::LOCK_EX) }
          held.push(lock_path)
          yield
        ensure
          held.delete(lock_path)
          lock.close
        end
      end

      # Runs one of ensure's own file operations on the tree at where; a
      # system error becomes an Error naming the tree, and the operation's
      # own message names the file.
      def filesystem(where)
        yield
      rescue SystemCallError => error
        raise Error, "cannot generate into #{where}: #{error.message}"
      end

      # One generator's plan; a system error while it reads its inputs
      # becomes an Error naming the generator, with the file in its message.
      def plan(generator, root:)
        generator.plan.call(root)
      rescue SystemCallError => error
        raise Error, "the #{generator.name} generator cannot read its input: #{error.message}"
      end

      # Each regular file beneath output, relative to it => its SHA-256.
      def tree_digests(output)
        Dir.glob('**/*', File::FNM_DOTMATCH, base: output).sort.filter_map do |relative|
          path = File.join(output, relative)
          [relative, Digest::SHA256.file(path).hexdigest] if File.file?(path)
        end.to_h
      end

      def merge_agreeing(into, table, what:)
        table.each do |key, value|
          raise Error, "generators disagree on the #{what} of #{key}" if into.key?(key) && into.fetch(key) != value

          into[key] = value
        end
      end

      # path with its longest existing prefix resolved through links, so two
      # spellings of one place compare equal before it exists.
      def resolved(path)
        path = File.expand_path(path)
        return File.realpath(path) if File.exist?(path)

        parent = File.dirname(path)
        parent == path ? path : File.join(resolved(parent), File.basename(path))
      end

      def code_digests(generators) = generators.map(&:code).reduce({}, :merge).sort.to_h

      def parents(relative)
        parts = relative.split('/')[0...-1]
        parts.each_index.map { |index| parts[0..index].join('/') }
      end

      def path?(relative)
        relative.is_a?(String) && relative.bytesize <= 1024 && PATH.match?(relative) &&
          relative.split('/').none? { |part| ['.', '..'].include?(part) }
      end

      def pattern?(pattern)
        pattern.is_a?(String) && pattern.bytesize <= 1024 && PATTERN.match?(pattern) &&
          pattern.split('/').none? { |part| ['.', '..'].include?(part) }
      end

      def checked_path(relative)
        raise Error, "invalid generated path #{relative.inspect}" unless path?(relative)

        relative
      end
    end
  end
end
