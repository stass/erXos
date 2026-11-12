# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'digest'
require 'fileutils'
require 'json'
require_relative 'compile_memo'
require_relative 'error'
require_relative 'fiasco'
require_relative 'interpreter_image'
require_relative 'pack_provenance'

module Erx
  # A program that runs as the root task on Fiasco: C17 from liberx's fiasco
  # backend, plus whatever a caller adds, freestanding, linked with Fiasco's own
  # l4sys and libsigma0 and at the fixed address its link gives root.ld. Fiasco's build
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
    # QEMU virt's RAM starts here. A root's place is an address in it that root.ld takes
    # from its link (place_flags): a system image's comes from its machine
    # (ProductionImage::Machine#root_address), and every other root, a test's, takes
    # PLACE, 64 MiB into RAM, the place of the development machine.
    RAM_FIRST = 0x4000_0000
    PLACE = RAM_FIRST + (64 << 20)
    # What every root task needs: its entry, its console and its compiler's memcpy.
    RUNTIME = %W[#{BACKEND}/arch/aarch64/root_start.S #{BACKEND}/console.c #{BACKEND}/root_mem.c].freeze
    # The root's own memory and objects: the effects over sigma0 and the four pure cores.
    VM = %W[#{BACKEND}/vm.c #{BACKEND}/page_pool.c #{BACKEND}/object.c liberx/backend/core/vm_table.c
            liberx/backend/core/grow_table.c liberx/backend/core/handles.c #{BACKEND}/fault_gate.c #{BACKEND}/budget.c
            liberx/backend/core/gate.c].freeze
    # The root service and what it runs on: threads, waits and the end path. The
    # crash writer comes in source, since Fiasco's boot archive holds no crash core.
    SERVICE = %W[#{BACKEND}/service.c #{BACKEND}/service_task.c #{BACKEND}/service_wire.c #{BACKEND}/arch/aarch64/cache.c #{BACKEND}/service_stubs.c #{BACKEND}/slice.c #{BACKEND}/thread.c
                 #{BACKEND}/arch/aarch64/thread_start.S #{BACKEND}/thread_claim.c #{BACKEND}/umtx.c #{BACKEND}/umtx_table.c
                 liberx/backend/core/object_info.c
                 #{BACKEND}/park.c liberx/backend/core/park_table.c #{BACKEND}/group.c #{BACKEND}/irq.c #{BACKEND}/time.c #{BACKEND}/time_page.c #{BACKEND}/time_table.c
                 #{BACKEND}/entropy.c kernel/core/rng.c kernel/crypto/blake3/blake3.c kernel/crypto/blake3/blake3_portable.c
                 kernel/crypto/chacha20/chacha.c
                 #{BACKEND}/watchdog_thread.c #{BACKEND}/end.c liberx/backend/core/trace_ring.c #{BACKEND}/trace.c
                 #{BACKEND}/arch/aarch64/clock.c kernel/core/crash.c kernel/core/crash_frame.c kernel/core/log.c
                 kernel/core/watchdog.c kernel/core/admit.c kernel/core/debug_log.c kernel/core/dispatch.c
                 build/gen/kernel/generated/abi_decode.c build/gen/kernel/generated/abi_run.c].freeze
    # What ERTS's lane port driver (erx_lane_drv.c) calls: the lanes, the funnel and the
    # ETF reader and writer, which hashes atoms with BLAKE3.
    CONNECTION = %w[liberx/erx_lane.c liberx/erx_funnel.c liberx/erx_etf.c].freeze
    # The domain library: its pure core, its apply phase and install funnel, and the lanes it sizes.
    DOMAIN_LIBRARY = %w[liberx/system/dom_core.c liberx/system/dom_life.c liberx/system/dom_apply.c
                        liberx/system/dom_boot.c liberx/system/dom_boot_view.c liberx/system/dom_install.c
                        liberx/system/dom_dump.c].freeze
    # The root's way to the archive: the record, the launcher and the manifest's reader.
    LAUNCH = %W[#{BACKEND}/root_open.c #{BACKEND}/launcher.c #{BACKEND}/boot_args.c kernel/core/boot_handoff.c build/gen/liberx/generated/abi_reader.c].freeze
    # A task's own program: its entry, its console and memcpy, and the stubs and
    # threads it reaches the service through.
    TASK = %W[#{BACKEND}/arch/aarch64/task_start.S #{BACKEND}/task_start.c #{BACKEND}/console.c #{BACKEND}/root_mem.c
              #{BACKEND}/service_stubs.c liberx/backend/core/gate.c liberx/backend/core/grow_table.c #{BACKEND}/thread.c
              #{BACKEND}/arch/aarch64/thread_start.S #{BACKEND}/thread_claim.c #{BACKEND}/umtx.c #{BACKEND}/umtx_table.c #{BACKEND}/park.c liberx/backend/core/park_table.c #{BACKEND}/time.c #{BACKEND}/time_table.c
              #{BACKEND}/arch/aarch64/clock.c #{BACKEND}/arch/aarch64/cache.c #{BACKEND}/trace_stub.c].freeze
    # A task's test program linked with musl: TASK's entry, less root_mem.c, whose memcpy
    # musl gives, with libc_task.c, which stops the task with main's return. libc-test's
    # tasks are built from it.
    LIBC_TASK = [*(TASK - ["#{BACKEND}/root_mem.c"]), "#{BACKEND}/libc_start.c", "#{BACKEND}/libc_task.c"].freeze
    # A session's program (docs/design-programs.md, "Starting a program"): LIBC_TASK's
    # entry with program_task.c for libc_task.c, liberx's program layer, which takes the
    # startup message from the channel's inbound lane and checks it with the generated
    # profile reader over the ETF reader, which hashes atoms with BLAKE3, and the backend
    # names the layer calls by, with task_refused.c for those a task has no service answer
    # for. The programs suite's programs are built from it.
    PROGRAM_LAYER = %w[liberx/program/program.c liberx/program/startup.c liberx/erx_lane.c
                       liberx/erx_profile.c build/gen/liberx/generated/prog_profile.c liberx/erx_etf.c
                       kernel/crypto/blake3/blake3.c kernel/crypto/blake3/blake3_portable.c].freeze
    PROGRAM = [*(LIBC_TASK - ["#{BACKEND}/libc_task.c"]), "#{BACKEND}/program_task.c", "#{BACKEND}/api_names.c",
               "#{BACKEND}/task_refused.c",
               *PROGRAM_LAYER].freeze
    # The root that checks the handoff and the archive and has nothing to run: the boot
    # suite's. The archive's core comes from Fiasco's boot archive, which does not hold the
    # handoff record's core, since bootstrap only writes it.
    NO_PROGRAM = [*RUNTIME, *VM, *SERVICE, *LAUNCH, "#{BACKEND}/root.c", "#{BACKEND}/root_no_program.c"].freeze
    # The system's root task, less what its link takes from musl and ERTS: musl supplies
    # the memcpy and the rest of what root_mem.c gives a freestanding root.
    SYSTEM = [*(RUNTIME - ["#{BACKEND}/root_mem.c"]), *VM, *SERVICE, *LAUNCH, "#{BACKEND}/root.c",
              'liberx/backend/core/boot_info.c', 'liberx/backend/core/boot_manifest.c', 'liberx/backend/core/refused.c',
              "#{BACKEND}/api_names.c", "#{BACKEND}/libc_start.c", "#{BACKEND}/libc_root_start.c", "#{BACKEND}/libc_root_write.c", "#{BACKEND}/runtime_entry.c",
              "#{BACKEND}/park_report.c", "#{BACKEND}/runtime_main.c", 'liberx/release.c', 'liberx/release_fs.c',
              *DOMAIN_LIBRARY, *CONNECTION].freeze
    # A domain's runtime image: the interpreter ERTS as a task's program, at task.ld's
    # fixed addresses, since erx_image_map loads only an ERX_IMAGE_FIXED image. musl's
    # start enters ERTS's main through domain_entry.c, which first checks the boot page;
    # the boot information reader comes as it comes to the root, release_task.c reads the
    # release from its slice through the service, and
    # task_refused.c answers the calls the service does not answer a task, and dom_lib_none.c
    # the domain library's entries, since only the root builds a library. One
    # image serves every domain (docs/design-runtime.md, "The build").
    # What a domain's runtime writes reaches the console as debug log records of its space, one
    # per line (docs/design-runtime.md, "The console and standard I/O"): this is a record's head,
    # as erx_log_render writes it, for a pattern to put before the line it expects. A Regexp, so
    # it keeps its own flags inside an extended pattern, whose # would otherwise open a comment.
    DOMAIN_RECORD = /\#\d+ \d+\.\d+ debug space \d+(?: dropped \d+)?: /n
    DOMAIN_RUNTIME = [*(TASK - ["#{BACKEND}/root_mem.c"]), "#{BACKEND}/libc_start.c", "#{BACKEND}/domain_entry.c", 'liberx/backend/core/line_gather.c',
                      "#{BACKEND}/runtime_main.c", 'liberx/backend/core/boot_info.c', 'liberx/backend/core/boot_manifest.c',
                      'liberx/backend/core/refused.c', 'liberx/backend/core/object_info.c', 'kernel/core/log.c', "#{BACKEND}/api_names.c",
                      "#{BACKEND}/task_refused.c", 'liberx/backend/core/dom_lib_none.c', "#{BACKEND}/release_task.c", 'liberx/release_fs.c', 'liberx/system/dom_dump.c',
                      'kernel/crypto/blake3/blake3.c', 'kernel/crypto/blake3/blake3_portable.c', *CONNECTION].freeze
    # The sources that read musl's headers, which NativeRuntime's sysroot holds: the boot page builder,
    # the domain library, the native_domain root and string functions that link it, and a
    # program's layer and the programs suite's programs that read what it keeps.
    LIBC_SOURCES = %w[liberx/backend/core/boot_info.c liberx/system/dom_core.c liberx/system/dom_life.c
                      liberx/system/dom_apply.c liberx/system/dom_boot.c liberx/system/dom_boot_view.c liberx/system/dom_install.c liberx/system/dom_dump.c
                      liberx/erx_lane.c liberx/erx_funnel.c
                      liberx/erx_etf.c test/guest/native_domain/guest.c
                      test/guest/native_domain/string.c
                      liberx/program/program.c liberx/program/startup.c liberx/erx_profile.c
                      build/gen/liberx/generated/prog_profile.c test/guest/programs/args.c
                      test/guest/programs/bigargs.c].freeze
    LIBC_HEADERS = 'build/runtime/native/sysroot/include'
    # The sources that use the FP registers, which a task may (only the kernel runs no FP
    # instruction): erx_etf.c reads and writes floats.
    FP_SOURCES = %w[liberx/erx_etf.c].freeze
    FLAGS = %w[--target=aarch64-none-elf -std=c17 -Wall -Wextra -Werror -pedantic -O2 -ffreestanding
               -fno-stack-protector -mgeneral-regs-only -mno-outline-atomics -I build/gen -I build/gen/include -I include -I kernel/crypto -I build/gen/kernel/generated -I kernel/core -I .].freeze
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
    def build_system(directory:, archives:, place:)
      program = build(name: 'stopgap-root', sources: SYSTEM, directory: directory, archives: archives, strip_debug: true,
                      place: place)
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
    def build_system_receipted(directory:, archives:, place:)
      program = build_system(directory: directory, archives: archives, place: place)
      receipted(program, sources: SYSTEM, script: LINK_SCRIPT, directory: directory)
    end

    # A domain's runtime image (DOMAIN_RUNTIME) over the archives that hold ERTS and musl,
    # with its receipt, as build_system_receipted gives the root's. It is the interpreter
    # image too, which InterpreterImage checks for JIT and C++ before anything packs it.
    def build_domain_runtime_receipted(directory:, archives:)
      program = build(name: 'erts-emu', sources: DOMAIN_RUNTIME, directory: directory, archives: archives, strip_debug: true,
                      script: TASK_LINK_SCRIPT, link_flags: TASK_LINK_FLAGS, place: nil)
      InterpreterImage.check(program: program, nm: File.join(File.dirname(@compiler), 'llvm-nm'), runner: @runner)
      receipted(program, sources: DOMAIN_RUNTIME, script: TASK_LINK_SCRIPT, directory: directory)
    end

    # The BeamAsm image: DOMAIN_RUNTIME over the archives of ERTS's BeamAsm flavour, musl
    # and the C++ runtime (NativeJitRuntime), with its receipt. The check that it links
    # BeamAsm and asmjit keeps an interpreter link from passing as it. The link map keeps
    # C++ names mangled: a demangled one such as `std::(anonymous namespace)::x` reads
    # as an input contribution to the map's reader (PackProvenance.contributors).
    def build_jit_runtime_receipted(directory:, archives:)
      program = build(name: 'erts-jit', sources: DOMAIN_RUNTIME, directory: directory, archives: archives, strip_debug: true,
                      script: TASK_LINK_SCRIPT, link_flags: [*TASK_LINK_FLAGS, '--no-demangle'], place: nil)
      InterpreterImage.check_beamasm(program: program, nm: File.join(File.dirname(@compiler), 'llvm-nm'), runner: @runner)
      receipted(program, sources: DOMAIN_RUNTIME, script: TASK_LINK_SCRIPT, directory: directory)
    end

    # The linker flag that gives root.ld its place: an address in RAM on a page boundary.
    def self.place_flags(place)
      raise Error, format('a root place must be a page-aligned address in RAM, not 0x%x', place) unless
        place.is_a?(Integer) && place >= RAM_FIRST && (place % 4096).zero?

      [format('--defsym=erx_fiasco_image_start=0x%x', place)]
    end

    # A task's program over archives, at task.ld's fixed addresses, with its receipt, as
    # build_domain_runtime_receipted gives the runtime's: what a production image's packer
    # takes for a program it carries in a release (the programs suite's, ProductionImage's
    # Added entries).
    def build_task_receipted(name:, sources:, directory:, archives:)
      program = build(name: name, sources: sources, directory: directory, archives: archives, strip_debug: true,
                      script: TASK_LINK_SCRIPT, link_flags: TASK_LINK_FLAGS, place: nil)
      receipted(program, sources: sources, script: TASK_LINK_SCRIPT, directory: directory)
    end

    # A task's program for the boot image: fixed addresses, as task.ld gives.
    def build_task(name:, sources:, directory:, flags: [])
      build(name: name, sources: sources, directory: directory, flags: flags, script: TASK_LINK_SCRIPT, link_flags: TASK_LINK_FLAGS,
            place: nil)
    end

    # Compiles sources in source's tree and links them into directory/name, with Fiasco's
    # boot archive, which holds the cores the service reads a program with, and any
    # further archives. Headers of
    # Fiasco are system headers here: they are inherited, so -pedantic judges only
    # erXos's own code. place is where root.ld puts the program; a task.ld link, whose
    # addresses are task.ld's own, passes nil.
    def build(name:, sources:, directory:, archives: [], flags: [], script: LINK_SCRIPT, link_flags: [], strip_debug: false,
              place: PLACE)
      objects = compile_all(sources: sources, directory: directory, flags: flags)
      libraries = LIBRARIES.map { |library| @fiasco.user_library(library) }
      program = File.join(directory, name)
      @runner.run([@linker, '-T', script, *(place ? self.class.place_flags(place) : []), *link_flags, *ROOT_LINK_FLAGS, *(strip_debug ? ['--strip-debug'] : []), '-Map', map_path(program),
                   '-o', program, *objects,
                   # The archives name one another's symbols in no fixed order, so the linker
                   # rescans them as a group until nothing new resolves.
                   '--start-group', *archives, @fiasco.boot_core_archive, *libraries, '--end-group'],
                  name: "native-root-#{name}-link", deadline: 60, chdir: @source)
      program
    end

    # The objects of sources, for a caller that links many programs from them. A source
    # whose inputs did not change since a compile of it is not compiled again (CompileMemo).
    def compile_all(sources:, directory:, flags: [])
      FileUtils.mkdir_p(directory)
      memo = CompileMemo.new(root: @root, runner: @runner)
      sources.map { |source| compile(source, directory: directory, flags: flags, memo: memo) }
    end

    private

    def compile(source, directory:, flags:, memo:)
      object = object_path(source, directory)
      headers = @fiasco.user_include_directories.flat_map { |path| ['-isystem', path] }
      # musl declares the BSD memory primitives (bcmp, bcopy, bzero) only under _BSD_SOURCE,
      # which -std=c17 leaves undefined.
      libc = LIBC_SOURCES.include?(source) ? ['-isystem', LIBC_HEADERS, '-D_BSD_SOURCE'] : []
      base = FP_SOURCES.include?(source) ? FLAGS - ['-mgeneral-regs-only'] : FLAGS
      argv = [@compiler, *base, *flags, *headers, *libc, '-MMD', '-MF', "#{object}.d", '-c', source, '-o', object]
      memo.compile(argv, chdir: @source, object: object, depfile: "#{object}.d") do |command, environment|
        @runner.run(command, name: "native-root-#{File.basename(source).tr('.', '-').downcase}", deadline: 60, chdir: @source,
                             env: environment)
      end
      object
    end

    def object_path(source, directory) = File.join(directory, "#{source.tr('/', '_').tr('.', '_')}.o")

    def map_path(program) = "#{program}.map"

    # A linked receipt over program: its objects, compiled from sources into directory,
    # their dependency files, the link map and the link script; and every file it names.
    def receipted(program, sources:, script:, directory:)
      compiles = sources.map { |source| compile_record(source, directory: directory) }
      linked = {
        'version' => 1, 'kind' => 'linked', 'artifact' => reference(program),
        'linker_map' => reference(map_path(program)).merge('format' => 'lld', 'directory' => '.'),
        'compiles' => compiles, 'archives' => [], 'inputs' => [reference(File.join(@root, script))]
      }
      receipt = File.join(directory, "#{File.basename(program)}.receipt.json")
      File.write(receipt, JSON.pretty_generate(linked) + "\n")
      named = compiles.flat_map { |record| [record.fetch('object'), record.fetch('dependency'), *record.fetch('sources')] }
      inputs = [program, map_path(program), receipt, File.join(@root, script),
                *named.map { |file| File.expand_path(file.fetch('path'), @root) }].uniq
      { program: program, receipt: receipt, inputs: inputs.freeze }.freeze
    end

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
