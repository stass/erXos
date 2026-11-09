# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require_relative 'build_memo'
require_relative 'pack_provenance'

module Erx
  # One clang compile's object and dependency file by what the compile reads (BuildMemo),
  # so a build whose sources did not change copies them instead of compiling again. The
  # memo decides how the compile runs, so that what it keys is what clang sees: the
  # command gains --no-default-config, which keeps clang from reading configuration files
  # from its install and the user's home, and runs in ENVIRONMENT with every other
  # variable unset. What a compile reads is then:
  # * its command, which names the compiler, the source, the flags and the outputs, and
  #   the directory it runs in;
  # * the compiler (BuildMemo.program_identity) and ENVIRONMENT;
  # * the headers it includes from its -I directories, which its dependency file names
  #   (-MMD), each by content;
  # * the system headers, which -MMD leaves out: every directory clang searches that is
  #   not an -I directory (its -isystem directories and its own resource headers), whole,
  #   by content;
  # * the absence of every file that would shadow a header it found: a system header
  #   that a file of the same relative name in an -I directory would replace, and for each
  #   dependency, a file of the name a search found it under in any -I directory or in
  #   the directory of any file the compile read, where a quoted include looks first.
  # The headers a compile read are known only after it ran, so the key is in two parts:
  # the base over the command, the compiler, the environment, the system headers and
  # their shadowing, under which the memo notes the dependency list of the last compile,
  # and the key over the base, the contents of those dependencies and their shadowing,
  # under which the outputs are stored. A compile whose dependencies changed while it ran is not
  # stored, since its object may hold either version, and neither is one that asks
  # whether a file exists (ABSENCE_PROBE), since no dependency list names a file it did
  # not find.
  class CompileMemo
    STEP = 'native-compile'
    NOTES = 'native-compile-inputs'
    # The whole environment of a compile and of its search probe.
    ENVIRONMENT = BuildMemo::TOOL_ENVIRONMENT
    # Preprocessor probes whose answer depends on a file the search may not find.
    ABSENCE_PROBE = /__has_include|#\s*include_next/n
    MAX_HEADER = 64 * 1024 * 1024

    # runner runs clang's search probe (search).
    def initialize(root:, runner:, memo: BuildMemo.new(root: root))
      @runner = runner
      @memo = memo
      @searches = {}
    end

    # Unless the memo holds the object and depfile of argv's compile for these inputs,
    # which are then copied into place, runs the block with the command and the
    # environment to run, which compile argv's source in chdir and write object and
    # depfile. Returns true when the block ran.
    def compile(argv, chdir:, object:, depfile:)
      command = [argv.first, '--no-default-config', *argv.drop(1)]
      base = base_key(command, chdir)
      outputs = [object, depfile]
      known = find_dependencies(base)
      key = known && full_key(base, known, command, chdir)
      return false if key && @memo.restore(STEP, key: key, outputs: outputs)

      started = Time.now
      yield command, environment
      read = dependencies(depfile)
      key = full_key(base, read, command, chdir)
      if key && read.all? { |path| unchanged_since?(File.expand_path(path, chdir), started) }
        @memo.store(STEP, key: key, outputs: outputs)
        @memo.write_note(NOTES, base, read)
      end
      true
    end

    private

    def environment = BuildMemo.tool_environment

    def unchanged_since?(path, started) = File.file?(path) && File.mtime(path) < started

    def base_key(command, chdir)
      search = search(command, chdir)
      BuildMemo.key('argv' => command, 'directory' => File.expand_path(chdir),
                    'compiler' => BuildMemo.program_identity(command.first), 'environment' => ENVIRONMENT,
                    'system' => search.fetch(:system), 'shadowing' => search.fetch(:shadowing))
    end

    # The key over base and what the compile read: each dependency by content, and for
    # each name a search could have found it under (its path below an -I directory or
    # below the directory of a file read), whether a file of that name exists in each of
    # those directories, where it might be found first. nil when a dependency probes for
    # a file (ABSENCE_PROBE).
    def full_key(base, read, command, chdir)
      files = read.map { |path| File.expand_path(path, chdir) }
      directories = (search(command, chdir).fetch(:quoted) + files.map { |file| File.dirname(file) }).uniq
      parts = read.zip(files).map do |path, file|
        bytes = File.file?(file) ? BoundedFile.read(file, maximum: MAX_HEADER) : nil
        return nil if bytes && ABSENCE_PROBE.match?(bytes)

        names = directories.filter_map { |directory| file.delete_prefix("#{directory}/") if file.start_with?("#{directory}/") }
        shadows = names.uniq.map { |name| [name, directories.map { |directory| File.exist?(File.join(directory, name)) }] }
        [path, bytes ? Digest::SHA256.hexdigest(bytes) : 'absent', shadows]
      end
      BuildMemo.key('base' => base, 'dependencies' => parts)
    end

    def find_dependencies(base)
      value = @memo.find_note(NOTES, base)
      return nil if value.nil?
      raise Error, "invalid #{NOTES} note; remove #{BuildMemo::OUTPUT}" unless
        value.is_a?(Array) && value.all? { |path| path.is_a?(String) && !path.empty? }

      value
    end

    def dependencies(depfile)
      _targets, sources = PackProvenance.dependencies(File.binread(depfile))
      sources
    end

    # Where clang looks for headers under command's flags, as clang -v lists it: the -I
    # directories (quoted, absolute), and the digest of each other directory, the system
    # ones, with the system headers that a file in an -I directory would shadow. Asked
    # once per compiler and flag set, which a build's compiles share.
    def search(command, chdir)
      flags = search_flags(command)
      probe = [command.first, *flags, '-E', '-v', '-x', 'c', File::NULL, '-o', File::NULL]
      @searches[[probe, chdir]] ||= begin
        record = @runner.run(probe, name: 'native-compile-search', deadline: 30, chdir: chdir, env: environment)
        lines = BoundedFile.read(record.fetch('log'), maximum: 1 << 20).lines.map(&:strip)
        listed = lines.drop_while { |line| !line.start_with?('#include "') }
                      .take_while { |line| line != 'End of search list.' }
                      .reject { |line| line.start_with?('#include') }
                      .map { |line| File.expand_path(line.delete_suffix(' (framework directory)'), chdir) }
        # A listing of another shape is refused: read as no directories, it would leave
        # the system headers out of every key.
        unless lines.include?('End of search list.') && !listed.empty?
          raise Error, "#{command.first} -v listed no header search directories"
        end

        requested = include_directories(flags).map { |directory| File.expand_path(directory, chdir) }
        quoted = listed.select { |directory| requested.include?(directory) }.uniq
        system = (listed - quoted).uniq
        names = system.flat_map { |directory| File.directory?(directory) ? Dir.glob('**/*', base: directory) : [] }.uniq
        shadowing = names.select { |name| quoted.any? { |directory| File.exist?(File.join(directory, name)) } }.sort
        { quoted: quoted.freeze, system: system.map { |directory| [directory, BuildMemo.tree_digest(directory)] },
          shadowing: shadowing }.freeze
      end
    end

    # command's flags without what names the source and the outputs, which does not move
    # the search.
    def search_flags(command)
      skip = false
      command.drop(1).each_with_object([]) do |argument, kept|
        if skip then skip = false
        elsif %w[-MF -o -c].include?(argument) then skip = true
        elsif argument != '-MMD' then kept << argument
        end
      end
    end

    def include_directories(flags)
      flags.each_cons(2).filter_map { |flag, value| value if flag == '-I' } +
        flags.filter_map { |flag| flag.delete_prefix('-I') if flag.start_with?('-I') && flag != '-I' }
    end
  end
end
