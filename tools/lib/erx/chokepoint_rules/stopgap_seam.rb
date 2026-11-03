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
        liberx/backend/fiasco/generated/calls.c
        liberx/backend/fiasco/generated/calls.h
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
        Chokepoints::Forbidden.new(
          name: 'one-erx-trap',
          rule: "kernel calls only through liberx: the ABI's trap only in liberx's erx backend, Fiasco's svc only " \
                'in its fiasco backend, and no other trap or raw instruction word in erXos C',
          design: "#{STOPGAP}#verification-and-testing",
          scope: ERXOS_C,
          pattern: TRAP,
          sites: [Chokepoints::Site.new(glob: 'liberx/backend/erx/arch/aarch64/**/*', permits: ERX_TRAP),
                  # Fiasco's own trap is svc #0.
                  Chokepoints::Site.new(glob: FIASCO_BACKEND, permits: /\Asvc[ \t]+#0\z/i),
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
        Chokepoints::Pending.new(
          name: 'glue-imports', rule: "a glue object's undefined symbols are all listed for its file in " \
                                      'fiasco/erx_glue_imports.txt',
          design: "#{STOPGAP}#interfaces",
          awaits: ['fiasco/erx_glue_imports.txt', GLUE],
          existing: ['fiasco/kernel/src/erx/erx_probe.cpp'],
          reason: "reads the glue's GCC objects from the kernel build"
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
