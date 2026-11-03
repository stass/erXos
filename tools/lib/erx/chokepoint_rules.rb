# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require_relative 'chokepoints'
require_relative '../../generated/abi'

module Erx
  # The chokepoint rules M1 binds, as data (docs/design-kernel.md,
  # "Chokepoint checks"; docs/design-stopgap.md, "Interfaces" and
  # "Verification and testing"). `make check` evaluates every rule over the
  # checkout's listed files; each active rule's seed is the violation its
  # host test feeds it. A rule whose sites are not in the tree yet is
  # Pending, and fails the check as soon as a file it awaits appears.
  #
  # These are text checks over the C view of each source. The design's
  # stronger evidence for the same rules, read from objects, the linked
  # kernel and syntax trees, is the object leg below, pending until the
  # target objects it reads are built.
  module ChokepointRules
    # The glue: erXos's C++ inside the stopgap kernel's tree.
    GLUE = 'fiasco/kernel/src/erx/**/*'
    FIASCO_BACKEND = 'liberx/backend/fiasco/**/*'
    # erXos's own C-family sources and the glue.
    ERXOS_C = Chokepoints::Scope.new(own: true, extra: [GLUE])
    # Outside the Fiasco backend, which alone speaks Fiasco's interface.
    ERXOS_C_OUTSIDE_FIASCO_BACKEND = Chokepoints::Scope.new(own: true, extra: [GLUE], except: [FIASCO_BACKEND])
    TRAP_OPCODE, TRAP_IMMEDIATE = ABI::Generated::SCHEMA.architecture.fetch(:trap).map(&:to_s)
    # A trap instruction, or a directive that places raw instruction words
    # or pulls in assembler text the check does not read.
    TRAP = /\b(?:svc|hvc|smc)\b(?:[ \t]+#?[0-9A-Fa-fx]+)?|\.(?:inst|word|long|[248]?byte|hword|quad|include|incbin)\b/i
    ERX_TRAP = /\A#{Regexp.escape(TRAP_OPCODE)}[ \t]+##{Regexp.escape(TRAP_IMMEDIATE)}\z/

    STOPGAP = 'docs/design-stopgap.md'
    KERNEL = 'docs/design-kernel.md'

    ACTIVE = [
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
        name: 'core-records-private',
        rule: "the cores' record definitions (kernel/core/*_impl.h) are included only by the cores (B4)",
        design: "#{STOPGAP}#invariants",
        scope: ERXOS_C,
        pattern: /\A\s*(?:#|%:)\s*include\w*\s*[<"][^>"]*_impl\.h[>"]/,
        sites: [Chokepoints::Site.new(glob: 'kernel/core/*')],
        seed: { 'fiasco/kernel/src/erx/seeded.cpp' => "#include \"kernel/core/cap_impl.h\"\n" }
      ),
      Chokepoints::Forbidden.new(
        name: 'seam-only-from-glue',
        rule: "the glue alone of the stopgap kernel's sources includes erXos's headers",
        design: "#{STOPGAP}#interfaces",
        scope: Chokepoints::Scope.new(own: false, extra: ['fiasco/kernel/**/*'], except: [GLUE]),
        pattern: %r{\A\s*(?:#|%:)\s*include\w*\s*[<"]erx/},
        seed: { 'fiasco/kernel/src/kern/seeded.cpp' => "#include \"erx/core/watchdog.h\"\n" }
      )
    ].freeze

    # Rules other checks enforce, each with the test that seeds its violation.
    ELSEWHERE = [
      Chokepoints::Elsewhere.new(
        name: 'core-archive-imports', rule: "the cores' archive leaves undefined only the erx_effect_* functions " \
                                             "and Fiasco's memcpy and memset",
        design: "#{STOPGAP}#interfaces", check: 'CoreArchive::UNDEFINED', test: 'test/host/core_archive_test.rb'
      ),
      Chokepoints::Elsewhere.new(
        name: 'arch-terms', rule: "an architecture's terms appear only in its layer and its documents",
        design: "#{KERNEL}#chokepoint-checks", check: 'ArchTerms', test: 'test/host/arch_terms_test.rb'
      ),
      Chokepoints::Elsewhere.new(
        name: 'generated-files', rule: 'generated files are never edited',
        design: "#{KERNEL}#chokepoint-checks", check: 'the generators\' --check drift runs',
        test: 'test/host/abi_generation_test.rb'
      ),
      Chokepoints::Elsewhere.new(
        name: 'kernel-stack-proof', rule: 'kernel C recurses only through musttail, and every frame is proven',
        design: "#{KERNEL}#chokepoint-checks", check: 'StackProof', test: 'test/host/stack_proof_test.rb'
      ),
      Chokepoints::Elsewhere.new(
        name: 'json-input', rule: 'host tooling parses JSON only through JsonInput',
        design: 'docs/design-build.md', check: 'Checks::JSON_OUTSIDE_WRITING', test: 'test/host/checks_test.rb'
      )
    ].freeze

    # The liberx files that exist before its target objects are built and
    # checked; any other liberx file is a new site of the object leg.
    LIBERX_UNCHECKED_OBJECTS = %w[
      liberx/backend/erx/arch/aarch64/generated/calls.c liberx/backend/fiasco/generated/calls.c
      liberx/backend/fiasco/generated/calls.h liberx/backend/hosted/generated/calls.c
      liberx/backend/hosted/generated/calls.h liberx/elf_plan.c liberx/generated/abi_reader.c
      liberx/generated/calls.h
    ].freeze

    # M1's rules whose sites are not in the tree. Each awaits the scope it
    # will police, either the files the design names as its first sites or
    # a whole directory less the files already there, which it lists; a new
    # file in that scope fails the check until the rule is implemented and
    # moved to ACTIVE.
    PENDING = [
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
      ),
      Chokepoints::Pending.new(
        name: 'grace-tracker-lock', rule: "only the grace tracker takes the tracker's lock (K13)",
        design: "#{KERNEL}#chokepoint-checks",
        awaits: ['kernel/core/*grace*', 'kernel/core/*tracker*'],
        reason: 'reads relocations of the cores'
      ),
      Chokepoints::Pending.new(
        name: 'cap-slot-private', rule: "only the capability table's code reads a slot, and one function clears " \
                                        'it (K1, K21, K25)',
        design: "#{KERNEL}#chokepoint-checks",
        awaits: ['kernel/core/cap*', 'include/erx/core/cap*'],
        reason: "reads clang's syntax trees and the cores' relocations"
      ),
      Chokepoints::Pending.new(
        name: 'budget-counters', rule: "only erx_budget_adjust changes a budget's counters, and kernel memory " \
                                       'is allocated only through the budget-charging funnel (K3, K32)',
        design: "#{KERNEL}#chokepoint-checks",
        awaits: ['kernel/core/budget*', 'include/erx/core/budget*'],
        reason: "reads clang's syntax trees and the cores' relocations"
      ),
      Chokepoints::Pending.new(
        name: 'object-leg', rule: 'the text rules above also hold in the target objects: no object outside ' \
                                  "liberx's fiasco backend references an l4_ symbol or holds a trap but the ABI's",
        design: "#{KERNEL}#chokepoint-checks",
        awaits: ['liberx/**/*'],
        existing: LIBERX_UNCHECKED_OBJECTS,
        reason: "reads liberx's target objects, which no build produces yet"
      )
    ].freeze

    ALL = (ACTIVE + ELSEWHERE + PENDING).freeze
  end
end
