# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'digest'
require 'fileutils'
require 'json'
require_relative 'error'
require_relative 'fiasco'
require_relative 'interpreter_image'
require_relative 'pack_provenance'

module Erx
  # A program that runs as the root task on Fiasco: C17 from liberx's fiasco
  # backend, plus whatever a caller adds, freestanding, linked with Fiasco's own
  # l4sys and libsigma0 and at the fixed address root.ld gives. Fiasco's build
  # must have run: its headers and libraries are this build's inputs.
  class NativeRoot
    BACKEND = 'liberx/backend/fiasco'
    LINK_SCRIPT = "#{BACKEND}/root.ld"
    TASK_LINK_SCRIPT = "#{BACKEND}/task.ld"
    # A section task.ld does not name would take the segments of the one before it, and a
    # writable one after .tbss would shrink every thread's TLS, so such a link fails.
    TASK_LINK_FLAGS = %w[--orphan-handling=error].freeze
    # Flags of every link that build makes, root and task. The scripts place each segment
    # on a page of its own and the program has nothing to relocate, so the linker adds no
    # RELRO header: root.ld names no program headers and would get one for it, and task.ld
    # names its own, so there the flag changes nothing.
    ROOT_LINK_FLAGS = %w[-z max-page-size=4096 -z norelro].freeze
    # What every root task needs: its entry, its console and its compiler's memcpy.
    RUNTIME = %W[#{BACKEND}/arch/aarch64/root_start.S #{BACKEND}/console.c #{BACKEND}/root_mem.c].freeze
    # The root's own memory: the effects over sigma0 and the two pure cores.
    VM = %W[#{BACKEND}/vm.c #{BACKEND}/page_pool.c liberx/backend/core/vm_table.c].freeze
    # The root service and what it runs on: threads, waits and the end path. The
    # crash writer comes in source, since Fiasco's boot archive holds no crash core.
    SERVICE = %W[#{BACKEND}/service.c #{BACKEND}/service_task.c #{BACKEND}/service_wire.c #{BACKEND}/arch/aarch64/cache.c #{BACKEND}/service_stubs.c #{BACKEND}/thread.c
                 #{BACKEND}/arch/aarch64/thread_start.S #{BACKEND}/thread_claim.c #{BACKEND}/umtx.c #{BACKEND}/umtx_table.c
                 #{BACKEND}/park.c liberx/backend/core/park_table.c #{BACKEND}/group.c #{BACKEND}/irq.c #{BACKEND}/time.c #{BACKEND}/time_table.c
                 #{BACKEND}/entropy.c kernel/core/rng.c kernel/crypto/blake3/blake3.c kernel/crypto/blake3/blake3_portable.c
                 kernel/crypto/chacha20/chacha.c
                 #{BACKEND}/watchdog_thread.c #{BACKEND}/end.c
                 #{BACKEND}/arch/aarch64/clock.c kernel/core/crash.c kernel/core/crash_frame.c kernel/core/log.c
                 kernel/core/watchdog.c kernel/core/admit.c kernel/core/debug_log.c kernel/core/dispatch.c
                 kernel/generated/abi_decode.c kernel/generated/abi_run.c].freeze
    # The root's way to the archive: the record, the launcher and the manifest's reader.
    LAUNCH = %W[#{BACKEND}/root_open.c #{BACKEND}/launcher.c #{BACKEND}/boot_args.c kernel/core/boot_handoff.c liberx/generated/abi_reader.c].freeze
    # A task's own program: its entry, its console and memcpy, and the stubs and
    # threads it reaches the service through.
    TASK = %W[#{BACKEND}/arch/aarch64/task_start.S #{BACKEND}/task_start.c #{BACKEND}/console.c #{BACKEND}/root_mem.c
              #{BACKEND}/service_stubs.c #{BACKEND}/thread.c #{BACKEND}/arch/aarch64/thread_start.S #{BACKEND}/thread_claim.c
              #{BACKEND}/umtx.c #{BACKEND}/umtx_table.c #{BACKEND}/park.c liberx/backend/core/park_table.c #{BACKEND}/time_table.c
              #{BACKEND}/arch/aarch64/clock.c #{BACKEND}/arch/aarch64/cache.c].freeze
    # The root that checks the handoff and the archive and has nothing to run: the boot
    # suite's. The archive's core comes from Fiasco's boot archive, which does not hold the
    # handoff record's core, since bootstrap only writes it.
    NO_PROGRAM = [*RUNTIME, *VM, *SERVICE, *LAUNCH, "#{BACKEND}/root.c", "#{BACKEND}/root_no_program.c"].freeze
    # The system's root task, less what its link takes from musl and ERTS: musl supplies
    # the memcpy and the rest of what root_mem.c gives a freestanding root.
    SYSTEM = [*(RUNTIME - ["#{BACKEND}/root_mem.c"]), *VM, *SERVICE, *LAUNCH, "#{BACKEND}/root.c",
              'liberx/backend/core/boot_info.c', 'liberx/backend/core/boot_manifest.c', 'liberx/backend/core/refused.c',
              "#{BACKEND}/api_names.c", "#{BACKEND}/libc_start.c", "#{BACKEND}/libc_root_start.c", "#{BACKEND}/libc_root_write.c", "#{BACKEND}/runtime_entry.c",
              "#{BACKEND}/park_report.c", "#{BACKEND}/runtime_main.c", 'liberx/release.c', 'liberx/release_fs.c'].freeze
    # The sources of SYSTEM that read musl's headers, which NativeRuntime's sysroot holds.
    LIBC_SOURCES = %w[liberx/backend/core/boot_info.c].freeze
    LIBC_HEADERS = 'build/runtime/native/sysroot/include'
    FLAGS = %w[--target=aarch64-none-elf -std=c17 -Wall -Wextra -Werror -pedantic -O2 -ffreestanding
               -fno-stack-protector -mgeneral-regs-only -mno-outline-atomics -I include -I kernel/crypto -I kernel/generated -I kernel/core -I .].freeze
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

    # The system's root task, as the archive's boot/stopgap-root entry: SYSTEM over the
    # archives that hold ERTS and musl, with the objects' debug information left out. It is
    # the interpreter image, which this one link of it checks for JIT and C++ before
    # anything packs it.
    def build_system(directory:, archives:)
      program = build(name: 'stopgap-root', sources: SYSTEM, directory: directory, archives: archives, strip_debug: true)
      InterpreterImage.check(program: program, nm: File.join(File.dirname(@compiler), 'llvm-nm'), runner: @runner)
      program
    end

    # A root with nothing to run, as the archive's boot/stopgap-root entry.
    def build_no_program(directory:)
      build(name: 'stopgap-root', sources: NO_PROGRAM, directory: directory)
    end

    # The system's root task with the receipt that binds it to what the link took: its
    # objects, their dependency files and the link map (PackProvenance reads these). The
    # dependency files leave out Fiasco's, musl's and the compiler's headers, system
    # headers here, so the receipt names erXos's own sources. Fiasco's audit answers for
    # Fiasco's; TODO.md holds musl's. Returns the program, its receipt, and every file those name.
    def build_system_receipted(directory:, archives:)
      program = build_system(directory: directory, archives: archives)
      compiles = SYSTEM.map { |source| compile_record(source, directory: directory) }
      linked = {
        'version' => 1, 'kind' => 'linked', 'artifact' => reference(program),
        'linker_map' => reference(map_path(program)).merge('format' => 'lld', 'directory' => '.'),
        'compiles' => compiles, 'archives' => [], 'inputs' => [reference(File.join(@root, LINK_SCRIPT))]
      }
      receipt = File.join(directory, 'stopgap-root.receipt.json')
      File.write(receipt, JSON.pretty_generate(linked) + "\n")
      named = compiles.flat_map { |record| [record.fetch('object'), record.fetch('dependency'), *record.fetch('sources')] }
      inputs = [program, map_path(program), receipt, File.join(@root, LINK_SCRIPT),
                *named.map { |file| File.expand_path(file.fetch('path'), @root) }].uniq
      { program: program, receipt: receipt, inputs: inputs.freeze }.freeze
    end

    # A task's program for the boot image: fixed addresses, as task.ld gives.
    def build_task(name:, sources:, directory:, flags: [])
      build(name: name, sources: sources, directory: directory, flags: flags, script: TASK_LINK_SCRIPT, link_flags: TASK_LINK_FLAGS)
    end

    # Compiles sources in source's tree and links them into directory/name, with Fiasco's
    # boot archive, which holds the cores the service reads a program with, and any
    # further archives. Headers of
    # Fiasco are system headers here: they are inherited, so -pedantic judges only
    # erXos's own code.
    def build(name:, sources:, directory:, archives: [], flags: [], script: LINK_SCRIPT, link_flags: [], strip_debug: false)
      objects = compile_all(sources: sources, directory: directory, flags: flags)
      libraries = LIBRARIES.map { |library| @fiasco.user_library(library) }
      program = File.join(directory, name)
      @runner.run([@linker, '-T', script, *link_flags, *ROOT_LINK_FLAGS, *(strip_debug ? ['--strip-debug'] : []), '-Map', map_path(program),
                   '-o', program, *objects,
                   # The archives name one another's symbols in no fixed order, so the linker
                   # rescans them as a group until nothing new resolves.
                   '--start-group', *archives, @fiasco.boot_core_archive, *libraries, '--end-group'],
                  name: "native-root-#{name}-link", deadline: 60, chdir: @source)
      program
    end

    # The objects of sources, for a caller that links many programs from them.
    def compile_all(sources:, directory:, flags: [])
      FileUtils.mkdir_p(directory)
      sources.map { |source| compile(source, directory: directory, flags: flags) }
    end

    private

    def compile(source, directory:, flags:)
      object = object_path(source, directory)
      headers = @fiasco.user_include_directories.flat_map { |path| ['-isystem', path] }
      libc = LIBC_SOURCES.include?(source) ? ['-isystem', LIBC_HEADERS] : []
      @runner.run([@compiler, *FLAGS, *flags, *headers, *libc, '-MMD', '-MF', "#{object}.d", '-c', source, '-o', object],
                  name: "native-root-#{File.basename(source).tr('.', '-').downcase}", deadline: 60, chdir: @source)
      object
    end

    def object_path(source, directory) = File.join(directory, "#{source.tr('/', '_').tr('.', '_')}.o")

    def map_path(program) = "#{program}.map"

    def compile_record(source, directory:)
      object = object_path(source, directory)
      _targets, sources = PackProvenance.dependencies(File.binread("#{object}.d"))
      { 'object' => reference(object), 'dependency' => reference("#{object}.d"), 'directory' => '.',
        'sources' => sources.map { |path| reference(File.expand_path(path, @root)) } }
    end

    def reference(path)
      { 'path' => path.delete_prefix("#{@root}/"), 'sha256' => Digest::SHA256.file(path).hexdigest }
    end
  end
end
