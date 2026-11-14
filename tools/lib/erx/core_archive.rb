# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'digest'
require 'fileutils'
require 'json'
require 'tmpdir'
require_relative 'bounded_file'
require_relative 'build_memo'
require_relative 'error'
require_relative 'output_directory'
require_relative 'pack_provenance'

module Erx
  # The C17 cores as the stopgap kernel links them (docs/design-stopgap.md,
  # "Interfaces", Build): one recipe compiles every core of the kernel with
  # clang for AArch64, and one archive collects them. The same recipe
  # serves the stack proof, so the objects the proof reads at the archive's
  # level are the objects the kernel links.
  #
  # A built archive directory holds, beside erx_cores.a:
  # * each object with its .su frame file and a dependency record
  #   .NAME.o.d naming the object's sources by absolute path, which the
  #   Fiasco build audit reads like any inherited compile record;
  # * .erx-archive-inputs, the archive's members in order, the audit's
  #   construction record;
  # * seam/erx/core/, a copy of include/erx/core/ and of its generated
  #   headers in build/gen/include/erx/core/, the only erXos headers the
  #   glue's include path reaches.
  module CoreArchive
    # The recipe is part of what the archive's bytes depend on, so a
    # change to it discards the kernel build as a source change does.
    IMPLEMENTATION_SHA256 = Digest::SHA256.file(__FILE__).hexdigest.freeze
    # The core directories: each C source here is a core, which the chokepoint
    # rules and the sanitizer gate also hold to their own requirements.
    CORE_PATTERNS = %w[kernel/core/*.c kernel/sched/*.c].freeze
    PATTERNS = [*CORE_PATTERNS, 'kernel/crypto/*/*.c', 'build/gen/kernel/generated/*.c'].freeze
    # Cores the stopgap links into bootstrap, not into the kernel.
    BOOTSTRAP_SOURCES = %w[kernel/core/boot_place.c kernel/core/pack.c].freeze
    # Cores the stopgap's kernel does not link, which the root task links in user mode:
    # the device-tree reader, which reaches the tree through libfdt built with every
    # check on (docs/design-device-tree.md, "The reader"). The stopgap kernel reads
    # no tree of erXos's and links its own libfdt, so the reader waits for erXos's
    # kernel to be linked into one.
    ROOT_TASK_SOURCES = %w[kernel/core/dt.c].freeze
    # What bootstrap links: those cores with what they call, and the image planner
    # the root's service reads an image entry with (NativeRoot links this archive). Translation is off
    # when they run, so every load and store must be aligned.
    BOOT_SOURCES = [*BOOTSTRAP_SOURCES, 'kernel/arch/aarch64/cpu_id.c', 'kernel/crypto/blake3/blake3.c', 'kernel/crypto/blake3/blake3_portable.c',
                    'liberx/elf_plan.c', 'liberx/image_plan.c', 'build/gen/liberx/generated/abi_reader.c'].freeze
    BOOT_FLAGS = %w[-mstrict-align].freeze
    BOOT_ARCHIVE = 'erx_boot.a'
    FLAGS = %w[--no-default-config -std=c17 -Wall -Wextra -Werror -pedantic --target=aarch64-none-elf -ffreestanding
               -mgeneral-regs-only -mno-outline-atomics -fstack-usage -ffunction-sections
               -I build/gen -I build/gen/include -I include -I build/gen/kernel/generated -I kernel/crypto].freeze
    LEVEL = '-O2'
    ARCHIVE = 'erx_cores.a'
    MEMBERS = '.erx-archive-inputs'
    SEAM = 'seam'
    SEAM_SOURCE = 'include/erx/core'
    # The seam's generated headers (abi_trap.h, abi_crash.h).
    SEAM_GENERATED = 'build/gen/include/erx/core'
    # The only symbols the archive may leave undefined: the effects its
    # host provides and Fiasco's memcpy and memset. Anything else would be
    # a call into Fiasco that no effect declares.
    UNDEFINED = /\A(?:erx_effect_[a-z0-9_]{1,1000}|memcpy|memset)\z/
    SYMBOL = /\A[A-Za-z_.$][A-Za-z0-9_.$]{0,4095}\z/
    # llvm-nm's types of a reference: undefined, and weak undefined.
    UNDEFINED_TYPES = %w[U w v].freeze
    # The compiles and their tools run in the build memo's fixed environment, and clang
    # reads no configuration file (--no-default-config in FLAGS), so nothing outside what
    # the Fiasco build's key names changes the archive the kernel links.
    def self.environment = BuildMemo.tool_environment

    # The archive as built: its path, its objects by source, and the
    # directory to give the glue as its one erXos include path.
    Built = Data.define(:archive, :objects, :seam)

    module_function

    # The core sources under root, the bootstrap ones included.
    def core_files(root) = CORE_PATTERNS.flat_map { |pattern| Dir.glob(pattern, base: root) }.sort

    # Every kernel core under root, sorted so that the archive, the graph
    # and the report come out the same on every run.
    def sources(root)
      found = PATTERNS.flat_map { |pattern| Dir.glob(pattern, base: root) }.sort
      missing = BOOTSTRAP_SOURCES - found
      raise Error, "C17 cores: bootstrap source #{missing.first} is missing" unless missing.empty?

      cores = found - BOOTSTRAP_SOURCES - ROOT_TASK_SOURCES
      raise Error, 'C17 cores: no kernel core sources' if cores.empty?

      names = cores.map { |source| object_name(source) }
      duplicate = names.tally.find { |_name, count| count > 1 }
      raise Error, "C17 cores: two sources compile to #{duplicate.first}" if duplicate

      cores
    end

    # Compiles each source under root at level into directory, a fresh
    # directory the caller owns, so no .su file of an earlier build can
    # stand in for an object's frames. The compile runs from root with
    # relative paths, so the frames name the tree's files and not this
    # host's checkout. Returns the objects by source.
    def compile(root:, sources:, level:, compiler:, runner:, directory:, extra_flags: [])
      sources.to_h do |source|
        object = File.join(directory, object_name(source))
        raw = File.join(directory, ".#{File.basename(object)}.raw.d")
        runner.run([compiler, *FLAGS, *extra_flags, level, '-MD', '-MF', raw, '-c', source, '-o', object],
                   name: 'core-compile', deadline: 120, chdir: root, env: environment)
        record = dependency_record(BoundedFile.read(raw, maximum: PackProvenance::MAX_METADATA),
                                   object: File.basename(object), root: root)
        File.write(File.join(directory, ".#{File.basename(object)}.d"), record)
        File.unlink(raw)
        [source, object]
      end
    end

    # Builds the kernel cores' archive under output from the tree at root.
    # The tree holds its generated files under build/gen, brought up to
    # date by the caller (Fiasco captures them with its other inputs).
    # Before anything is installed, check is called with the built objects
    # (the stack proof), and the undefined symbols are checked; a refusal
    # leaves output as it was. An output whose files already equal the new
    # build is kept as it is, so an unchanged archive keeps its time and the
    # inherited make does not relink.
    def build(root:, compiler:, runner:, output:, project:, check: ->(_objects) {})
      tools = tools_beside(compiler)
      parent = OutputDirectory.prepare(root: project, path: File.dirname(output))
      raise Error, 'C17 core archive directory is a symlink' if File.symlink?(output)

      Dir.mktmpdir('.cores-', parent) do |temporary|
        staged = File.join(temporary, 'tree')
        FileUtils.mkdir_p(staged)
        objects = compile(root: root, sources: sources(root), level: LEVEL, compiler: compiler,
                          runner: runner, directory: staged)
        check_undefined(listing(objects.values, tools: tools, runner: runner))
        check.call(objects)
        archive(objects.values, directory: staged, tools: tools, runner: runner)
        copy_seam(root: root, directory: staged)
        install(staged, output: output, temporary: temporary) unless same_tree?(staged, output)
      end
      Built.new(archive: File.join(output, ARCHIVE),
                objects: sources(root).to_h { |source| [source, File.join(output, object_name(source))] },
                seam: File.join(output, SEAM))
    end

    # The archive bootstrap links, under output, from the tree at root.
    def build_boot(root:, compiler:, runner:, output:, project:)
      tools = tools_beside(compiler)
      parent = OutputDirectory.prepare(root: project, path: File.dirname(output))
      raise Error, 'C17 boot archive directory is a symlink' if File.symlink?(output)

      Dir.mktmpdir('.boot-cores-', parent) do |temporary|
        staged = File.join(temporary, 'tree')
        FileUtils.mkdir_p(staged)
        objects = compile(root: root, sources: BOOT_SOURCES, level: LEVEL, compiler: compiler, runner: runner,
                          directory: staged, extra_flags: BOOT_FLAGS)
        check_undefined(listing(objects.values, tools: tools, runner: runner))
        archive(objects.values, directory: staged, tools: tools, runner: runner, name: BOOT_ARCHIVE)
        copy_seam(root: root, directory: staged)
        install(staged, output: output, temporary: temporary) unless same_tree?(staged, output)
      end
      Built.new(archive: File.join(output, BOOT_ARCHIVE),
                objects: BOOT_SOURCES.to_h { |source| [source, File.join(output, object_name(source))] },
                seam: File.join(output, SEAM))
    end

    def object_name(source) = File.basename(source, '.c') + '.o'

    # clang's dependency output names the object as given with -o and the
    # sources relative to the compile's directory. The record names the
    # object by its file name and each source by absolute path, which is
    # what an audit of the archive's members resolves.
    def dependency_record(text, object:, root:)
      _targets, sources = PackProvenance.dependencies(text)
      raise Error, "C17 cores: no dependency record for #{object}" if sources.empty?

      paths = sources.map { |source| File.expand_path(source, root) }
      # The record is make syntax with no escapes, so a path that would
      # need one is refused rather than written ambiguously.
      unusual = paths.find { |path| path.match?(/[\s:\\#$%]/) }
      raise Error, "C17 cores: a source path needs make escapes: #{unusual.inspect}" if unusual

      ([object + ':'] + paths).join(" \\\n  ") + "\n"
    end

    # The symbols left undefined across all the objects, given llvm-nm's
    # POSIX listing of each: a symbol one member defines is not undefined.
    def undefined_symbols(listing)
      entries = listing_entries(listing)
      # Only a global definition satisfies a reference from another member:
      # a static of the same name does not, and a weak reference (w, v) is
      # a reference the link may bind to Fiasco like any other.
      defined = global_definitions(entries)
      entries.select { |_name, type| UNDEFINED_TYPES.include?(type) }.map(&:first).uniq.sort - defined
    end

    # Each symbol line of llvm-nm's POSIX listing as [name, type]. A line
    # whose second field is not one type letter is a member's header.
    def listing_entries(listing)
      listing.each_line.filter_map do |line|
        name, type = line.split(' ', 3)
        next unless name && type && type.size == 1

        raise Error, 'C17 cores: unreadable symbol listing' unless SYMBOL.match?(name)

        [name, type]
      end
    end

    # The globals the members define; each must be erXos's (erx_), so no
    # core shadows or is shadowed by a Fiasco function of the same name.
    def global_definitions(entries)
      entries.select { |_name, type| type.match?(/\A[A-Z]\z/) && !UNDEFINED_TYPES.include?(type) }.map(&:first)
    end

    def check_undefined(listing)
      refused = undefined_symbols(listing).grep_v(UNDEFINED)
      unless refused.empty?
        raise Error, "C17 cores: undefined symbol #{refused.first} is neither an erx_effect_* nor memcpy or memset"
      end

      foreign = global_definitions(listing_entries(listing)).grep_v(/\Aerx_/)
      raise Error, "C17 cores: global #{foreign.first} is not named erx_" unless foreign.empty?
    end

    def listing(objects, tools:, runner:)
      result = runner.run([tools.fetch(:nm), '--format=posix', '--no-sort', *objects],
                          name: 'core-symbols', deadline: 60, env: environment)
      BoundedFile.read(result.fetch('log'), maximum: PackProvenance::MAX_METADATA)
    end

    # A GNU-format archive with a symbol index, which the GNU linker of the
    # inherited build reads; llvm-ar writes it without times or owners.
    def archive(objects, directory:, tools:, runner:, name: ARCHIVE)
      runner.run([tools.fetch(:ar), '--format=gnu', 'rcsD', name, *objects.map { |path| File.basename(path) }],
                 name: 'core-archive', deadline: 60, chdir: directory, env: environment)
      File.write(File.join(directory, MEMBERS), objects.map { |path| File.basename(path) }.join(' ') + "\n")
    end

    # The seam's headers under root: each header's name => its root-relative
    # path, in include/erx/core/ or, generated, in build/gen/include/erx/core/.
    # The two share no header (Generated.ensure refuses a file of the tree at a
    # generated file's path), so each header has one origin for the build audit.
    def seam_headers(root)
      [SEAM_SOURCE, SEAM_GENERATED].each_with_object({}) do |source, found|
        Dir.glob('*.h', base: File.join(root, source)).each { |header| found[header] = File.join(source, header) }
      end.sort.to_h
    end

    def copy_seam(root:, directory:)
      target = File.join(directory, SEAM, SEAM_SOURCE.delete_prefix('include/'))
      FileUtils.mkdir_p(target)
      headers = seam_headers(root)
      raise Error, "C17 cores: no seam headers in #{SEAM_SOURCE}" if headers.empty?

      headers.each do |header, relative|
        File.binwrite(File.join(target, header),
                      BoundedFile.read(File.join(root, relative), maximum: PackProvenance::MAX_METADATA))
      end
    end

    def same_tree?(staged, output)
      File.directory?(output) && tree_record(staged) == tree_record(output)
    end

    def tree_record(directory)
      Dir.glob('**/*', File::FNM_DOTMATCH, base: directory).sort.filter_map do |relative|
        path = File.join(directory, relative)
        raise Error, "C17 core archive holds a link: #{relative}" if File.symlink?(path)
        next unless File.file?(path)

        [relative, Digest::SHA256.hexdigest(BoundedFile.read(path, maximum: PackProvenance::MAX_METADATA))]
      end
    end

    def install(staged, output:, temporary:)
      previous = File.join(temporary, 'previous')
      File.rename(output, previous) if File.exist?(output)
      begin
        File.rename(staged, output)
      rescue SystemCallError
        File.rename(previous, output) if File.exist?(previous)
        raise
      end
    end

    def tools_beside(compiler)
      directory = File.dirname(File.realpath(compiler))
      tools = { ar: 'llvm-ar', nm: 'llvm-nm' }.transform_values { |tool| File.join(directory, tool) }
      missing = tools.values.reject { |tool| File.file?(tool) && File.executable?(tool) }
      raise Error, "C17 cores: missing #{missing.join(', ')}" unless missing.empty?

      tools
    rescue SystemCallError => error
      raise Error, "C17 cores: no compiler to find the LLVM tools beside: #{error.message}"
    end

    private_class_method :dependency_record, :check_undefined, :listing_entries, :global_definitions, :listing, :archive, :copy_seam,
                         :same_tree?, :tree_record, :install, :tools_beside
  end
end
