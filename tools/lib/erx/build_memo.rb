# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'digest'
require 'etc'
require 'fileutils'
require 'json'
require 'tmpdir'
require_relative 'bounded_file'
require_relative 'host_os'
require_relative 'error'
require_relative 'json_input'
require_relative 'output_directory'

module Erx
  # What a build step made from its inputs, kept so that a later build whose step has the
  # same inputs reuses the outputs instead of running the step again. A step's key is the
  # SHA-256 of everything the step reads, named part by part (BuildMemo.key): sources by
  # content, the programs that run by identity (BuildMemo.program_identity), their argument
  # vectors and the environment they see. The key alone decides reuse, so a key that leaves
  # out an input reuses a stale output: each caller's key names every input of its step, and
  # its test changes each one in turn and expects the step to run again.
  #
  # A memo keeps its records under build/memo, one directory per step, in two forms:
  # * stored: the outputs are copied into the memo under their key and copied back into
  #   place on a hit, for a step whose output directory each build clears (a compile into
  #   an image's directory). Each key has its own entry, so going back to an earlier input
  #   finds that input's outputs again.
  # * in place: the step writes its outputs where they stay, and the memo records their
  #   SHA-256 beside the key; a hit needs each output still to have those bytes, so an
  #   output removed or rewritten since runs the step again.
  # Records are written to a temporary name and renamed, so an interrupted build leaves no
  # record that claims outputs it did not finish. A record of another shape is refused with
  # a diagnostic, never read as a miss or a hit.
  class BuildMemo
    VERSION = 1
    OUTPUT = 'build/memo'
    MAX_RECORD = 4 * 1024 * 1024
    MAX_OUTPUT = 512 * 1024 * 1024
    STEP_NAME = /\A[a-z0-9][a-z0-9-]*\z/
    KEY = /\A[0-9a-f]{64}\z/
    # The directories of the operating system's own programs. They change only with the
    # system's release (macOS keeps them on its sealed system volume), which every program
    # identity names (system_release).
    SYSTEM_DIRECTORIES = %w[/usr/bin /bin /usr/sbin /sbin].freeze
    # Whether the release names those directories' programs. On Linux a package upgrade
    # changes them under the same release, so there no record is reused: every step runs.
    REUSE = HostOs::MACOS
    SHARED_LIBRARY = /\.(?:dylib|so)\z|\.so\.[0-9.]+\z/
    # The whole environment of a compile whose output a key names (CompileMemo, and the
    # C17 cores the Fiasco build links, CoreArchive): with every other variable unset
    # (tool_environment), nothing a shell exports (CPATH, CCC_OVERRIDE_OPTIONS) reaches clang.
    TOOL_ENVIRONMENT = { 'PATH' => SYSTEM_DIRECTORIES.join(File::PATH_SEPARATOR), 'LC_ALL' => 'C', 'TZ' => 'UTC',
                         'SOURCE_DATE_EPOCH' => '0' }.freeze

    # The SHA-256 of parts, a Hash naming each input of a step: strings, integers and
    # arrays and hashes of them, hashes by sorted key, so the key does not depend on the
    # order the caller named its parts in.
    def self.key(parts) = Digest::SHA256.hexdigest(JSON.generate(['erx-build-memo', VERSION, canonical(parts)]))

    def self.canonical(value)
      case value
      when Hash then value.map { |name, member| [name.to_s, canonical(member)] }.sort_by(&:first)
      when Array then value.map { |member| canonical(member) }
      when String, Integer, true, false, nil then value
      else raise Error, "a build memo key part cannot be a #{value.class}"
      end
    end
    private_class_method :canonical

    # A program's identity for a key: where it really lives, the SHA-256 of its bytes and
    # of the shared libraries of its install, and the operating system's release; or that
    # it is absent. A driver's bytes alone would not name a compiler: clang's driver is a
    # few hundred kilobytes over libclang-cpp and libLLVM, the shared libraries in the lib
    # directory beside its bin directory, which install_libraries names by content. What a
    # program loads from the operating system the release names. Homebrew keeps each
    # version and revision of a package in a directory of its own, so the real path also
    # names the helpers a driver runs from its install by path (gcc's cc1, its libgcc.a).
    def self.program_identity(path)
      # A bare name would be found on the step's PATH, not here.
      raise Error, "build memo program #{path} is not an absolute path" unless path.to_s.start_with?('/')

      real = File.realpath(path)
      [real, file_digest(real), install_libraries(real), system_release].join(' ')
    rescue Errno::ENOENT
      # A program that is not there makes no output for a record to reuse: any step that
      # runs it fails.
      "#{path} absent"
    rescue SystemCallError => error
      raise Error, "cannot identify build program #{path}: #{error.message}"
    end

    # The SHA-256 of the shared libraries directly in the lib directory beside program's
    # bin directory, by name and content; none for a program of the operating system's.
    def self.install_libraries(program)
      bin = File.dirname(program)
      directory = File.expand_path('../lib', bin)
      return 'none' if SYSTEM_DIRECTORIES.include?(bin) || !File.directory?(directory)

      libraries = Dir.children(directory).select { |name| SHARED_LIBRARY.match?(name) }
                     .map { |name| File.join(directory, name) }.select { |library| File.file?(library) }
                     .map { |library| File.realpath(library) }.uniq.sort
      Digest::SHA256.hexdigest(libraries.map { |library| "#{File.basename(library)} #{file_digest(library)}" }.join("\n"))
    end

    # TOOL_ENVIRONMENT, with every variable of this process's environment it does not set
    # unset, for Process.spawn.
    def self.tool_environment = ENV.keys.to_h { |name| [name, nil] }.merge(TOOL_ENVIRONMENT)

    # The operating system and its release, which name its own programs and libraries.
    def self.system_release = Etc.uname.values_at(:sysname, :release, :version).join(' ')

    # The SHA-256 of a file, read once per process for each state of the file (its inode,
    # size and change and modification times), since a compiler's libraries are hundreds
    # of megabytes and every key of a build names them.
    def self.file_digest(path)
      stat = File.stat(path)
      @file_digests ||= {}
      @file_digests[[path, stat.ino, stat.size, stat.mtime.to_r, stat.ctime.to_r]] ||= Digest::SHA256.file(path).hexdigest
    end

    # The SHA-256 over every file below directory, by relative path and content: a tree a
    # step reads whole, such as a system header directory. A link to a file counts as the
    # content it reaches, which is what a compile reads through it; a link to a directory
    # is refused rather than followed, so the digest never misses a subtree or loops.
    def self.tree_digest(directory)
      return 'absent' unless File.directory?(directory)

      lines = Dir.glob('**/*', File::FNM_DOTMATCH, base: directory).sort.filter_map do |relative|
        next if relative.end_with?('/.') || relative == '.'

        path = File.join(directory, relative)
        raise Error, "build memo cannot key #{path}, a link to a directory" if File.symlink?(path) && File.directory?(path)

        if File.file?(path) then "#{relative} #{Digest::SHA256.file(path).hexdigest}"
        elsif File.symlink?(path) then "#{relative} absent"
        end
      end
      Digest::SHA256.hexdigest(lines.join("\n"))
    end

    # The SHA-256 of the build tools' own code, tools/erx and every file below tools/lib:
    # a step whose effect the Ruby decides (which files it copies, what it writes) runs
    # again when that Ruby changes.
    def self.tools_digest(root:)
      files = ['tools/erx', *Dir.glob('tools/lib/**/*', base: root).sort].select { |path| File.file?(File.join(root, path)) }
      Digest::SHA256.hexdigest(files.map { |path| "#{path} #{Digest::SHA256.file(File.join(root, path)).hexdigest}" }.join("\n"))
    end

    # root may be spelled through a link (a temporary directory under /var, which is
    # /private/var); outputs may be named under either spelling.
    # reuse is whether a stored record may stand in for a run (REUSE on this host).
    def initialize(root:, reuse: REUSE)
      @root = File.realpath(root)
      @reuse = reuse
      @roots = [@root, File.expand_path(root)].uniq.freeze
      @directory = File.join(@root, OUTPUT)
    end

    # Copies the outputs (absolute paths) a step stored under key into place, when the
    # entry holds each of them with its recorded bytes. Returns whether it did; on false the
    # caller runs the step and stores what it made.
    def restore(step, key:, outputs:)
      entry = entry_path(step, key)
      record = @reuse && find_record(File.join(entry, 'record.json'), key: key)
      return false unless record && record.fetch('outputs').is_a?(Hash) && record.fetch('outputs').keys == outputs.map { |path| File.basename(path) }

      copy_out(entry, record, outputs)
    end

    # Keeps a copy of the outputs a step just made under key, replacing an earlier entry.
    def store(step, key:, outputs:)
      names = outputs.map { |output| File.basename(output) }
      raise Error, 'build memo outputs of one step need distinct names' unless names.uniq == names

      entry = entry_path(step, key)
      Dir.mktmpdir('.entry-', File.dirname(entry)) do |temporary|
        staged = File.join(temporary, 'entry')
        Dir.mkdir(staged)
        recorded = outputs.to_h do |output|
          bytes = BoundedFile.read(output, maximum: MAX_OUTPUT)
          File.binwrite(File.join(staged, File.basename(output)), bytes)
          [File.basename(output), Digest::SHA256.hexdigest(bytes)]
        end
        write_record(File.join(staged, 'record.json'), key, recorded)
        FileUtils.rm_rf(entry)
        File.rename(staged, entry)
      end
    end

    # Runs the block unless step's record names key and each output it lists still has the
    # bytes recorded. Returns true when the block ran; the record then names key and the
    # outputs as the block left them.
    def in_place(step, key:, outputs:)
      path = File.join(step_directory(step), 'current.json')
      record = @reuse && find_record(path, key: key)
      return false if record && record.fetch('outputs') == digests(outputs.map { |output| relative(output) })

      FileUtils.rm_f(path)
      yield
      write_record(path, key, digests(outputs.map { |output| relative(output) }))
      true
    end

    # A value a step keeps between builds under a key of its own: what a compile last read,
    # which decides the key its outputs are stored under (CompileMemo).
    def find_note(step, key)
      record = find_record("#{entry_path(step, key)}.json", key: key)
      record&.fetch('outputs')
    end

    def write_note(step, key, value) = write_record("#{entry_path(step, key)}.json", key, value)

    private

    # Where step keeps what it holds under key; a key is checked before it names a file.
    def entry_path(step, key)
      raise Error, 'invalid build memo key' unless key.is_a?(String) && KEY.match?(key)

      File.join(step_directory(step), key)
    end

    def step_directory(step)
      raise Error, "invalid build memo step name #{step.inspect}" unless step.is_a?(String) && STEP_NAME.match?(step)

      OutputDirectory.prepare(root: @root, path: File.join(@directory, step))
    end

    # The record at path when it is one this memo wrote for key; nil when there is none or
    # it names another key.
    def find_record(path, key:)
      raise Error, 'invalid build memo key' unless key.is_a?(String) && KEY.match?(key)
      return nil unless File.exist?(path) || File.symlink?(path)

      record = JsonInput.parse(BoundedFile.read(path, maximum: MAX_RECORD), max_bytes: MAX_RECORD, label: 'build memo record')
      unless record.is_a?(Hash) && record.keys.sort == %w[key outputs version] && record['version'] == VERSION &&
             record['key'].is_a?(String) && KEY.match?(record['key'])
        raise Error, "invalid build memo record #{relative(path)}; remove #{OUTPUT}"
      end
      record['key'] == key ? record : nil
    end

    def write_record(path, key, outputs)
      bytes = JSON.generate({ 'version' => VERSION, 'key' => key, 'outputs' => outputs }) + "\n"
      atomic_write(path, bytes)
    end

    def atomic_write(path, bytes)
      Dir.mktmpdir('.memo-', File.dirname(path)) do |temporary|
        staged = File.join(temporary, 'file')
        File.binwrite(staged, bytes)
        File.rename(staged, path)
      end
    end

    # Each output by content: a file by its SHA-256, a directory by its tree's
    # (tree_digest), and anything else, a link included, as absent.
    def digests(paths)
      paths.to_h do |path|
        absolute = File.join(@root, path)
        digest = if File.symlink?(absolute) then 'absent'
                 elsif File.file?(absolute) then Digest::SHA256.file(absolute).hexdigest
                 elsif File.directory?(absolute) then "tree #{self.class.tree_digest(absolute)}"
                 else 'absent'
                 end
        [path, digest]
      end
    end

    def relative(path)
      expanded = File.expand_path(path)
      root = @roots.find { |candidate| expanded.start_with?("#{candidate}/") }
      raise Error, "build memo output #{path} lies outside #{@root}" unless root

      expanded.delete_prefix("#{root}/")
    end

    # Copies the entry's outputs into place when each still has its recorded bytes.
    def copy_out(entry, record, outputs)
      contents = outputs.map do |output|
        bytes = BoundedFile.read(File.join(entry, File.basename(output)), maximum: MAX_OUTPUT)
        return false unless Digest::SHA256.hexdigest(bytes) == record.fetch('outputs').fetch(File.basename(output))

        bytes
      end
      outputs.zip(contents).each do |output, bytes|
        FileUtils.mkdir_p(File.dirname(output))
        atomic_write(output, bytes)
      end
      true
    rescue Error
      false
    end
  end
end
