# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'fileutils'
require_relative 'error'
require_relative 'fiasco'

module Erx
  # A program that runs as the root task on Fiasco: C17 from liberx's fiasco
  # backend, plus whatever a caller adds, freestanding, linked with Fiasco's own
  # l4sys and libsigma0 and at the fixed address root.ld gives. Fiasco's build
  # must have run: its headers and libraries are this build's inputs.
  class NativeRoot
    BACKEND = 'liberx/backend/fiasco'
    LINK_SCRIPT = "#{BACKEND}/root.ld"
    # What every root task needs: its entry, its console and its compiler's memcpy.
    RUNTIME = %W[#{BACKEND}/arch/aarch64/root_start.S #{BACKEND}/console.c #{BACKEND}/root_mem.c].freeze
    # The system's root task. The archive's core comes from Fiasco's boot archive,
    # which does not hold the handoff record's core, since bootstrap only writes it.
    SYSTEM = [*RUNTIME, "#{BACKEND}/root.c", 'kernel/core/boot_handoff.c'].freeze
    FLAGS = %w[--target=aarch64-none-elf -std=c17 -Wall -Wextra -Werror -pedantic -O2 -ffreestanding
               -fno-stack-protector -mgeneral-regs-only -mno-outline-atomics -I include -I .].freeze
    LIBRARIES = %w[libsigma0.a libl4sys.p.a].freeze

    # source is the tree the C comes from, which a test may seed with a fault.
    def initialize(root:, runner:, compiler:, linker:, source: root, fiasco: Fiasco.new(root: root, runner: runner, compiler: compiler))
      raise Error, 'set ERX_CLANG to the installed LLVM clang' if compiler.to_s.empty?
      raise Error, 'set ERX_LLD to the installed ld.lld' if linker.to_s.empty?

      @root = File.expand_path(root)
      @source = File.expand_path(source)
      @runner = runner
      @compiler = compiler
      @linker = linker
      @fiasco = fiasco
    end

    # The system's root task, as the archive's boot/stopgap-root entry.
    def build_system(directory:)
      build(name: 'stopgap-root', sources: SYSTEM, directory: directory, archives: [@fiasco.boot_core_archive])
    end

    # Compiles sources in source's tree and links them, with any archives, into
    # directory/name. Headers of Fiasco are system headers here: they are
    # inherited, so -pedantic judges only erXos's own code.
    def build(name:, sources:, directory:, archives: [], flags: [])
      FileUtils.mkdir_p(directory)
      objects = sources.map { |source| compile(source, directory: directory, flags: flags) }
      libraries = LIBRARIES.map { |library| @fiasco.user_library(library) }
      program = File.join(directory, name)
      @runner.run([@linker, '-T', LINK_SCRIPT, '-o', program, *objects, *archives, *libraries],
                  name: "native-root-#{name}-link", deadline: 60, chdir: @source)
      program
    end

    private

    def compile(source, directory:, flags:)
      object = File.join(directory, "#{source.tr('/', '_').tr('.', '_')}.o")
      headers = @fiasco.user_include_directories.flat_map { |path| ['-isystem', path] }
      @runner.run([@compiler, *FLAGS, *flags, *headers, '-c', source, '-o', object],
                  name: "native-root-#{File.basename(source).tr('.', '-').downcase}", deadline: 60, chdir: @source)
      object
    end
  end
end
