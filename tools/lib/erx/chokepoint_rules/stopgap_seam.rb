# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

module Erx
  module ChokepointRules
    # Outside the Fiasco backend, which alone speaks Fiasco's interface.
    ERXOS_C_OUTSIDE_FIASCO_BACKEND = Chokepoints::Scope.new(own: true, extra: [GLUE], except: [FIASCO_BACKEND])
    TRAP_OPCODE, TRAP_IMMEDIATE = ABI::Generated::SCHEMA.architecture.fetch(:trap).map(&:to_s)
    # A trap instruction, or a directive that places raw instruction words
    # or pulls in assembler text the check does not read.
    TRAP = /\b(?:svc|hvc|smc)\b(?:[ \t]+#?[0-9A-Fa-fx]+)?|\.(?:inst|word|long|[248]?byte|hword|quad|include|incbin)\b/i
    ERX_TRAP = /\A#{Regexp.escape(TRAP_OPCODE)}[ \t]+##{Regexp.escape(TRAP_IMMEDIATE)}\z/

    # What keeps Fiasco's interface behind its backend and the glue, with the
    # stopgap's own pending rules: the seam every core and domain sits above.
    declare_group(
      # The liberx files the object leg has not read yet: the generated calls
      # and reader, and the ELF planner.
      unchecked_objects: %w[
        liberx/backend/erx/arch/aarch64/generated/calls.c
        liberx/backend/core/mem.h
        liberx/backend/core/refused.c
        liberx/backend/core/device_check.h
        liberx/backend/api.h
        liberx/backend/fiasco/api_names.c
        liberx/backend/hosted/arch/aarch64/switch_stack.S
        liberx/backend/hosted/group.c
        liberx/backend/hosted/internal.h
        liberx/backend/hosted/thread.c
        liberx/backend/hosted/vm.c
        liberx/backend/hosted/wait.c
        liberx/backend/fiasco/arch/aarch64/cache.c
        liberx/backend/fiasco/arch/aarch64/clock.c
        liberx/backend/fiasco/arch/aarch64/generated/trap.c
        liberx/backend/fiasco/arch/aarch64/root_start.S
        liberx/backend/fiasco/arch/aarch64/task_start.S
        liberx/backend/fiasco/arch/aarch64/thread_start.S
        liberx/backend/fiasco/cache.h
        liberx/backend/fiasco/console.c
        liberx/backend/fiasco/console.h
        liberx/backend/fiasco/end.c
        liberx/backend/fiasco/entropy.c
        liberx/backend/fiasco/entropy.h
        liberx/backend/fiasco/generated/calls.c
        liberx/backend/fiasco/generated/calls.h
        liberx/backend/fiasco/group.c
        liberx/backend/fiasco/group.h
        liberx/backend/fiasco/irq.c
        liberx/backend/fiasco/launcher.c
        liberx/backend/fiasco/launcher.h
        liberx/backend/fiasco/lock.h
        liberx/backend/fiasco/log.c
        liberx/backend/fiasco/log.h
        liberx/backend/fiasco/page_pool.c
        liberx/backend/fiasco/page_pool.h
        liberx/backend/fiasco/park.c
        liberx/backend/fiasco/park.h
        liberx/backend/core/park_table.c
        liberx/backend/core/park_table.h
        liberx/backend/fiasco/libc_start.c
        liberx/backend/fiasco/libc_start.h
        liberx/backend/fiasco/libc_root.c
        liberx/backend/fiasco/libc_task.c
        liberx/backend/fiasco/root.c
        liberx/backend/fiasco/root.ld
        liberx/backend/fiasco/root_open.c
        liberx/backend/fiasco/root_open.h
        liberx/backend/fiasco/root_mem.c
        liberx/backend/fiasco/root_mem.h
        liberx/backend/fiasco/service.c
        liberx/backend/fiasco/service.h
        liberx/backend/fiasco/service_task.c
        liberx/backend/fiasco/service_task.h
        liberx/backend/fiasco/service_stubs.c
        liberx/backend/fiasco/service_wire.c
        liberx/backend/fiasco/service_wire.h
        liberx/backend/fiasco/task.ld
        liberx/backend/fiasco/task_start.c
        liberx/backend/fiasco/task_start.h
        liberx/backend/fiasco/thread.c
        liberx/backend/fiasco/thread.h
        liberx/backend/fiasco/time.c
        liberx/backend/fiasco/time.h
        liberx/backend/fiasco/time_table.c
        liberx/backend/fiasco/time_table.h
        liberx/backend/fiasco/thread_claim.c
        liberx/backend/fiasco/thread_claim.h
        liberx/backend/fiasco/thread_offsets.h
        liberx/backend/fiasco/umtx.c
        liberx/backend/fiasco/umtx.h
        liberx/backend/fiasco/umtx_table.c
        liberx/backend/fiasco/umtx_table.h
        liberx/backend/fiasco/watchdog_thread.c
        liberx/backend/fiasco/watchdog_thread.h
        liberx/backend/fiasco/vm.c
        liberx/backend/fiasco/vm.h
        liberx/backend/core/vm_table.c
        liberx/backend/core/vm_table.h
        liberx/backend/hosted/generated/calls.c
        liberx/backend/hosted/generated/calls.h
        liberx/elf_plan.c
        liberx/generated/abi_reader.c
        liberx/generated/calls.h
      ],
      rules: [
        Chokepoints::IncludeForm.new(
          name: 'include-form',
          rule: 'every include in erXos C names a header by a plain path, so no computed include or included ' \
                'non-header carries text past the other rules',
          design: "#{KERNEL}#chokepoint-checks",
          scope: ERXOS_C,
          seed: { 'kernel/core/seeded.c' => "#define HIDDEN <l4/sys/ipc.h>\n#include HIDDEN\n" }
        ),
        Chokepoints::Forbidden.new(
          name: 'fiasco-headers-in-backend',
          rule: "only liberx's fiasco backend includes an l4sys header",
          design: "#{KERNEL}#chokepoint-checks",
          scope: ERXOS_C_OUTSIDE_FIASCO_BACKEND,
          pattern: %r{[<"]l4/|l4sys|l4re}i,
          seed: { 'liberx/seeded.c' => "#include <l4/sys/ipc.h>\n", 'kernel/core/seeded.c' => "#include <l4/re/env.h>\n" }
        ),
        # Names the backend's headers outside it, so a plain include of a
        # backend header cannot carry its Fiasco calls past the rules above.
        Chokepoints::Forbidden.new(
          name: 'fiasco-backend-headers-private',
          rule: "only liberx's fiasco backend includes the backend's headers",
          design: "#{KERNEL}#chokepoint-checks",
          scope: ERXOS_C_OUTSIDE_FIASCO_BACKEND,
          pattern: %r{backend/fiasco/}i,
          # The debug-log, memory, thread and crash probes as the root task are this
          # backend's own tests, and the host drivers and the wire's fuzz target test
          # its pure cores.
          # musl's seam is this backend's first client, until a neutral liberx header stands in front of it.
          sites: [Chokepoints::Site.new(glob: 'musl/src/internal/erxos/syscall.c'),
                  Chokepoints::Site.new(glob: 'musl/src/thread/erxos/clone.c'),
                  Chokepoints::Site.new(glob: 'test/guest/debug_log_probe/guest.c'),
                  Chokepoints::Site.new(glob: 'test/guest/function_api/guest.c'),
                  Chokepoints::Site.new(glob: 'test/guest/function_api/device_cases.c'),
                  Chokepoints::Site.new(glob: 'test/guest/native_memory/guest.c'),
                  Chokepoints::Site.new(glob: 'test/guest/native_threads/guest.c'),
                  Chokepoints::Site.new(glob: 'test/guest/native_crash/guest.c'),
                  Chokepoints::Site.new(glob: 'test/guest/native_watchdog/guest.c'),
                  Chokepoints::Site.new(glob: 'test/guest/native_semaphore_race/guest.c'),
                  Chokepoints::Site.new(glob: 'test/guest/native_irq/guest.c'),
                  Chokepoints::Site.new(glob: 'test/guest/native_libc_test/guest.c'),
                  Chokepoints::Site.new(glob: 'test/guest/native_task/guest.c'),
                  Chokepoints::Site.new(glob: 'test/guest/native_task/program.c'),
                  Chokepoints::Site.new(glob: 'test/fixtures/fiasco_vm_driver.c'),
                  Chokepoints::Site.new(glob: 'test/fixtures/fiasco_umtx_driver.c'),
                  Chokepoints::Site.new(glob: 'test/fixtures/fiasco_park_driver.c'),
                  Chokepoints::Site.new(glob: 'test/fixtures/fiasco_claim_driver.c'),
                  Chokepoints::Site.new(glob: 'test/fixtures/fiasco_time_driver.c'),
                  Chokepoints::Site.new(glob: 'tools/fuzz/service_wire_fuzz.c')],
          seed: { 'kernel/core/seeded.c' => "#include \"liberx/backend/fiasco/generated/calls.h\"\n" }
        ),
        Chokepoints::Forbidden.new(
          name: 'fiasco-symbols-in-backend',
          rule: "no erXos source outside liberx's fiasco backend references an l4_ symbol",
          design: "#{KERNEL}#chokepoint-checks",
          scope: ERXOS_C_OUTSIDE_FIASCO_BACKEND,
          pattern: /\bl4(?:re|util)?_[A-Za-z0-9_]*/,
          seed: { 'kernel/core/seeded.c' => "void f(void) { l4_ipc_call(0, 0, 0, 0); }\n",
                  'liberx/seeded.c' => "void f(void) { l4re_env(); }\n" }
        ),
        # Bytes on this console reach the operator's terminal. Text attributed
        # to a source (a log record, a name) reaches it through the line
        # escape or the log's ASCII class; a program's own output goes out unchanged, as on Unix.
        Chokepoints::Forbidden.new(
          name: 'fiasco-console-sink',
          rule: "only liberx's fiasco console writes to the kernel's log object, and only the root task's report, " \
                "the root's memory effects' fixed refusals, the entropy banner line, the end path's crash frame, the service's and the reaper's fixed refusals, " \
                "the memory, thread, crash, watchdog and interrupt transcripts, the debug log and the standard output of the root and of " \
                "a task, through the service, call it",
          design: "#{STOPGAP}#the-console",
          scope: ERXOS_C,
          pattern: /\b(?:l4_vcon_write(?:_u)?|erx_fiasco_console_write)\b/,
          sites: [Chokepoints::Site.new(glob: 'liberx/backend/fiasco/console.[ch]'),
                  Chokepoints::Site.new(glob: 'liberx/backend/fiasco/root.c', permits: /\Aerx_fiasco_console_write\z/),
                  Chokepoints::Site.new(glob: 'liberx/backend/fiasco/libc_root.c', permits: /\Aerx_fiasco_console_write\z/),
                  Chokepoints::Site.new(glob: 'liberx/backend/fiasco/log.c', permits: /\Aerx_fiasco_console_write\z/),
                  Chokepoints::Site.new(glob: 'liberx/backend/fiasco/vm.c', permits: /\Aerx_fiasco_console_write\z/),
                  Chokepoints::Site.new(glob: 'liberx/backend/fiasco/end.c', permits: /\Aerx_fiasco_console_write\z/),
                  Chokepoints::Site.new(glob: 'liberx/backend/fiasco/entropy.c', permits: /\Aerx_fiasco_console_write\z/),
                  Chokepoints::Site.new(glob: 'liberx/backend/fiasco/service.c', permits: /\Aerx_fiasco_console_write\z/),
                  Chokepoints::Site.new(glob: 'liberx/backend/fiasco/service_task.c', permits: /\Aerx_fiasco_console_write\z/),
                  Chokepoints::Site.new(glob: 'liberx/backend/fiasco/thread.c', permits: /\Aerx_fiasco_console_write\z/),
                  Chokepoints::Site.new(glob: 'test/guest/native_memory/guest.c', permits: /\Aerx_fiasco_console_write\z/),
                  Chokepoints::Site.new(glob: 'test/guest/native_threads/guest.c', permits: /\Aerx_fiasco_console_write\z/),
                  Chokepoints::Site.new(glob: 'test/guest/native_crash/guest.c', permits: /\Aerx_fiasco_console_write\z/),
                  Chokepoints::Site.new(glob: 'test/guest/function_api/guest.c'),
                  Chokepoints::Site.new(glob: 'test/guest/native_watchdog/guest.c', permits: /\Aerx_fiasco_console_write\z/),
                  Chokepoints::Site.new(glob: 'test/guest/native_semaphore_race/guest.c', permits: /\Aerx_fiasco_console_write\z/),
                  Chokepoints::Site.new(glob: 'test/guest/native_irq/guest.c', permits: /\Aerx_fiasco_console_write\z/),
                  Chokepoints::Site.new(glob: 'test/guest/native_libc_test/guest.c', permits: /\Aerx_fiasco_console_write\z/),
                  Chokepoints::Site.new(glob: 'test/guest/native_task/guest.c', permits: /\Aerx_fiasco_console_write\z/)],
          seed: { 'liberx/backend/fiasco/seeded.c' => "void f(void) { l4_vcon_write(0, \"x\", 1); }\n",
                  'liberx/backend/fiasco/root.c' => "void f(void) { l4_vcon_write(0, \"x\", 1); }\n" }
        ),
        # The range table and the pool take no lock, because the service alone runs a
        # body once it is up, and the first thread only before that.
        Chokepoints::Forbidden.new(
          name: 'fiasco-vm-body-callers',
          rule: "only the root service, and the thread table's setup before the service runs, call the vm bodies",
          design: "#{STOPGAP}#the-root-service",
          scope: ERXOS_C,
          pattern: /\berx_fiasco_vm_body\b/,
          sites: [Chokepoints::Site.new(glob: 'liberx/backend/fiasco/vm.[ch]'),
                  Chokepoints::Site.new(glob: 'liberx/backend/fiasco/service.c'),
                  Chokepoints::Site.new(glob: 'liberx/backend/fiasco/service_task.c')],
          seed: { 'liberx/backend/fiasco/seeded.c' => "void f(void) { erx_fiasco_vm_body(0, 0, 0, 0, 0); }\n" }
        ),
        Chokepoints::Forbidden.new(
          name: 'one-erx-trap',
          rule: "kernel calls only through liberx: the ABI's trap only in liberx's erx and fiasco backends, " \
                'and no other trap or raw instruction word in erXos C',
          design: "#{STOPGAP}#verification-and-testing",
          scope: ERXOS_C,
          pattern: TRAP,
          sites: [Chokepoints::Site.new(glob: 'liberx/backend/erx/arch/aarch64/**/*', permits: ERX_TRAP),
                  Chokepoints::Site.new(glob: FIASCO_BACKEND, permits: ERX_TRAP),
                  # The stack proof's host fixtures plant raw instruction
                  # words its extractor must refuse; no build links them.
                  Chokepoints::Site.new(glob: 'test/fixtures/stack_graph/*.c', permits: /\A\.inst\z/)],
          seed: { 'kernel/core/seeded.c' => "void f(void) { __asm__ volatile(\"sv\\\nc #0\"); }\n",
                  'kernel/core/escaped.c' => "void f(void) { __asm__ volatile(\"mov x0, #1\\n\\tsvc #0\"); }\n",
                  'kernel/core/joined.c' => "void f(void) { __asm__ volatile(\"s\" \"vc #0\"); }\n",
                  'kernel/core/word.c' => "void f(void) { __asm__ volatile(\".word 0xd4000001\"); }\n",
                  'liberx/backend/erx/arch/aarch64/seeded.c' => "void g(void) { __asm__ volatile(\"svc #0\"); }\n" }
        ),
        Chokepoints::Forbidden.new(
          name: 'seam-only-from-glue',
          rule: "the glue alone of the stopgap kernel's sources includes erXos's headers",
          design: "#{STOPGAP}#interfaces",
          scope: Chokepoints::Scope.new(own: false, extra: ['fiasco/kernel/**/*'], except: [GLUE]),
          pattern: %r{#{INCLUDE}[<"]erx/}i,
          seed: { 'fiasco/kernel/src/kern/seeded.cpp' => "#include \"erx/core/watchdog.h\"\n" }
        ),
        Chokepoints::Pending.new(
          name: 'vector-route', rule: 'every user-mode vector entry is one direct branch to one of the three ' \
                                      'erXos stubs, and erx_user_sync_entry classifies first (B1)',
          design: "#{STOPGAP}#verification-and-testing",
          awaits: ['fiasco/kernel/src/erx/entry.cpp', 'tools/check_vectors.rb'],
          reason: 'reads the vector table and the stubs in the kernel disassembly'
        ),
        Chokepoints::Elsewhere.new(
          name: 'glue-imports', rule: "a glue object's undefined symbols are all listed for its file in " \
                                      'fiasco/erx_glue_imports.txt',
          design: "#{STOPGAP}#interfaces", check: 'GlueImports, on every kernel build',
          test: 'test/host/glue_imports_test.rb'
        ),
        Chokepoints::Pending.new(
          name: 'raw-allocator-sites', rule: "the linked kernel's call sites of the raw page allocator are the " \
                                             'funnel and the listed boot-time functions (B9)',
          design: "#{STOPGAP}#verification-and-testing",
          awaits: ['fiasco/erx_boot_allocators.txt', 'fiasco/kernel/src/erx/budget.cpp'],
          reason: "reads the linked kernel's call graph"
        ),
        Chokepoints::Pending.new(
          name: 'pmem-converter-sites', rule: 'Mem_layout::pmem_to_phys, Mem_layout::phys_to_pmem and ' \
                                              "Kmem::kdir->virt_to_phys are called only from their listed callers",
          design: "#{STOPGAP}#risks-and-open-questions",
          awaits: ['fiasco/kernel/src/erx/thread.cpp'],
          reason: "reads the linked kernel's call graph; the callers are inherited Fiasco's"
        )
      ]
    )
  end
end
