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

    INCLUDE = Chokepoints::INCLUDE_PREFIX

    # An include of the header at path by any path ending in its file name,
    # in any case, as a case-insensitive file system resolves it.
    def self.include_of(path) = %r{#{INCLUDE}[<"](?:[^>"]*/)?#{Regexp.escape(File.basename(path))}[>"]}i

    # A use of a record's tag that is not one of the forms that only refer
    # to the record: a pointer or reference (*, &), the end of a
    # declaration or argument (; , )), or a declarator named after it
    # (typedef struct erx_budget erx_budget_t;). Every definition puts
    # something else after the tag (a brace, a base clause, final, an
    # attribute) or a line break, so any spelling of one is refused,
    # including those through a macro, and a declaration split after the
    # tag is refused too, on the safe side. A tag a macro pastes together
    # (erx_ ## budget) gets past it.
    def self.record_use(*tags)
      /\b(?:#{tags.map { |tag| Regexp.escape(tag) }.join('|')})\b(?!\s*(?:[*&;),]|[A-Za-z_]\w*\s*[;,)]))/
    end

    # The host tests of a core's source, which alone besides the core see
    # its private records: the drivers named after it in test/fixtures and
    # its fuzzer. Neither tree is built into the kernel or any image, and a
    # test of the core is named after it, so a new one needs no new entry.
    def self.host_tests(source)
      stem = File.basename(source, '.c')
      ["test/fixtures/#{stem}_*.c", "tools/fuzz/#{stem}_fuzz.c"].freeze
    end

    # The budget core's private header, which only the core and this host
    # driver include.
    BUDGET_IMPL = 'kernel/core/budget_impl.h'
    BUDGET_DRIVER = 'test/fixtures/budget_driver.c'
    BUDGET_IMPL_INCLUDE = include_of(BUDGET_IMPL)
    BUDGET_RECORD_USE = record_use('erx_budget', 'erx_reserve')

    # The capability core and the hand-written header of its table record.
    CAP_CORE = 'kernel/core/cap.c'
    CAP_IMPL = 'kernel/core/cap_impl.h'
    CAP_IMPL_INCLUDE = include_of(CAP_IMPL)
    # The one function that clears a slot, by its whole name; a name a macro
    # pastes together (erx_cap_slot_ ## clear) does not match.
    CAP_SLOT_CLEAR = /\berx_cap_slot_clear\b/

    # The layouts the ABI file marks private, each with its owner. Their
    # records, offsets and accessors are only in their generated headers;
    # include/erx/abi.h declares only each one's tag, size and alignment.
    PRIVATE_LAYOUTS = ABI::Generated::SCHEMA.type_order
                                            .map { |name| ABI::Generated::SCHEMA.types.fetch(name) }
                                            .select { |type| type.is_a?(ABI::Layout) && type.private? }.freeze
    # Each private layout's owner's host tests, each allowed to include
    # that layout's generated header.
    PRIVATE_LAYOUT_TEST_SITES = PRIVATE_LAYOUTS.flat_map do |layout|
      host_tests(layout.private_owner).map do |test|
        Chokepoints::Site.new(glob: test, permits: include_of(layout.private_header))
      end
    end.freeze
    # The capability slot's generated header, which the rules below name.
    CAP_SLOT_IMPL = ABI::Generated::SCHEMA.types.fetch('erx_cap_slot').private_header

    # The cores' private headers among paths: every header named *_impl.h,
    # in any case, anywhere below kernel/ (a core's hand-written header in
    # kernel/core, kernel/sched or any later core directory, and each
    # private layout's generated header in kernel/generated), except in an
    # import, a directory below kernel/ with an ORIGIN.md. An import's own
    # header of the same suffix (kernel/crypto/blake3/blake3_impl.h) is
    # not one of them.
    def self.private_headers(paths)
      imports = paths.filter_map { |path| "#{File.dirname(path)}/" if File.basename(path) == 'ORIGIN.md' }
      paths.select { |path| File.fnmatch?('kernel/**/*_impl.h', path, File::FNM_PATHNAME | File::FNM_CASEFOLD) }
           .reject { |path| imports.any? { |import| path.start_with?(import) } }
    end

    # The private headers of this checkout, read once at load so a new one
    # is covered without an entry here, with each private layout's header
    # named even before it is generated. The checks run on this checkout,
    # so the set is the checked tree's.
    REPOSITORY = File.expand_path('../../..', __dir__)
    PRIVATE_HEADERS = (private_headers(Dir.glob('kernel/**/*', base: REPOSITORY)) |
                       PRIVATE_LAYOUTS.map(&:private_header)).sort.freeze
    raise Error, "no private core header below #{REPOSITORY}/kernel" if (PRIVATE_HEADERS & [BUDGET_IMPL, CAP_IMPL]).empty?

    # An include of any of them, by any path ending in its file name, in
    # any case.
    PRIVATE_HEADER_INCLUDE = Regexp.union(PRIVATE_HEADERS.map { |header| include_of(header) })

    # A private layout's rule, built from the ABI file: only the layout's
    # owner and the owner's host tests include its generated header, and no
    # other file names its record's tag but to refer to it. Everywhere else
    # the layout is an incomplete type, so a member, an offset or an
    # accessor of it does not compile, and this rule keeps it so. It reads
    # the stopgap kernel's tree, glue and inherited sources alike. Its seed
    # is built from the layout too: includes from other files, by other
    # paths and in other cases, and definitions of the record in each form,
    # the owner's included.
    def self.private_layout_rule(layout)
      header = layout.private_header
      owner = layout.private_owner
      tag = layout.name
      name = File.basename(header, '_impl.h')
      includers = [owner, *host_tests(owner)].map { |glob| Chokepoints::Site.new(glob: glob, permits: include_of(header)) }
      definition = Chokepoints::Site.new(glob: header, permits: record_use(tag))
      Chokepoints::Forbidden.new(
        name: "#{name.tr('_', '-')}-private",
        rule: "only #{owner}, which the ABI file names as the owner of #{tag}, and its host tests include " \
              "#{header}, and no other file names struct #{tag} but to refer to it",
        design: 'docs/design-abi.md#source-grammar',
        scope: Chokepoints::Scope.new(own: true, extra: ['fiasco/kernel/**/*']),
        pattern: Regexp.union(include_of(header), record_use(tag)),
        sites: [*includers, definition],
        seed: { 'kernel/core/seeded_core.c' => "#include \"#{File.basename(header)}\"\n",
                'liberx/seeded.c' => "#include \"#{header}\"\n",
                'fiasco/kernel/src/erx/seeded.cpp' => "#include <#{File.basename(header).upcase}>\n",
                'test/fixtures/seeded_driver.c' => "#include \"#{File.basename(header)}\"\n",
                'kernel/core/seeded_split.c' => "struct #{tag}\n{\n\tint member;\n};\n",
                'kernel/core/seeded_macro.c' => "#define R #{tag}\nstruct R { int member; };\n",
                'fiasco/kernel/src/kern/seeded.cpp' => "struct alignas(64) #{tag} final { };\n",
                owner => "union #{tag} { int member; };\n" }
      )
    end

    # The lane reader, the one file that reaches a lane's pages, and the
    # names that reach them: the shared layouts of a lane's ring header,
    # reader page and record, their generated accessors, and the offsets
    # of a side's parts.
    LANE_READER = 'liberx/erx_lane.c'
    LANE_LAYOUT = /\b(?:erx_lane_(?:hdr|rpage|rec)\w*|ERX_LANE_(?:HDR|RPAGE|REC|SIDE)_\w*)/
    # The inherited runtimes and C library erXos edits in place, where a
    # second reader could otherwise hide: no upstream name starts erx_.
    INHERITED_RUNTIME = %w[otp/**/* musl/**/*].freeze
    # OTP's inherited C++ JIT assembler, which uses trigraph-like text the
    # C view refuses and has no place for a lane.
    ASMJIT = 'otp/erts/emulator/asmjit/**/*'
    # The ABI generator's outputs that define those names; its other C
    # outputs name none of them and are read like any other file.
    ABI_C_OUTPUTS = %w[include/erx/abi.h include/erx/abi_reader.h liberx/generated/abi_reader.c
                       fuzz/generated/abi.c].freeze
    # The host producers that drive the reader in its tests; no build of
    # a runtime links them.
    LANE_PRODUCERS = %w[test/fixtures/lane_driver.c tools/fuzz/lane_fuzz.c].freeze

    STOPGAP = 'docs/design-stopgap.md'
    KERNEL = 'docs/design-kernel.md'
    DOMAINS = 'docs/design-domains.md'

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
        rule: "the cores' private headers (each *_impl.h below kernel/ outside an import: a core's own, " \
              'and each private ABI layout\'s generated header) are included only by the cores (B4), ' \
              'and each by its own core\'s host tests',
        design: "#{STOPGAP}#invariants",
        scope: ERXOS_C,
        pattern: PRIVATE_HEADER_INCLUDE,
        sites: [Chokepoints::Site.new(glob: 'kernel/core/*'),
                Chokepoints::Site.new(glob: BUDGET_DRIVER, permits: BUDGET_IMPL_INCLUDE),
                *host_tests(CAP_CORE).map { |test| Chokepoints::Site.new(glob: test, permits: CAP_IMPL_INCLUDE) },
                *PRIVATE_LAYOUT_TEST_SITES],
        seed: { 'fiasco/kernel/src/erx/seeded.cpp' => "#include \"kernel/core/cap_impl.h\"\n",
                'liberx/seeded.c' => "#import \"kernel/core/cap_IMPL.h\"\n" }
      ),
      # The budget core's counters are written only in kernel/core/budget.c
      # (K3, K32): its records are defined only in its private header, which
      # only the core and its host driver include, and every other file
      # names a record's tag only to refer to it. This text rule stands in
      # for the syntax-tree check of the counters' writes, budget-counters
      # below. It reads the stopgap kernel's tree, glue and inherited
      # sources alike.
      Chokepoints::Forbidden.new(
        name: 'budget-records-private',
        rule: "only kernel/core/budget.c and its host driver include #{BUDGET_IMPL}, and no other file " \
              'names struct erx_budget or struct erx_reserve but to refer to it',
        design: "#{KERNEL}#chokepoint-checks",
        scope: Chokepoints::Scope.new(own: true, extra: ['fiasco/kernel/**/*']),
        pattern: Regexp.union(BUDGET_IMPL_INCLUDE, BUDGET_RECORD_USE),
        sites: [Chokepoints::Site.new(glob: 'kernel/core/budget.c', permits: BUDGET_IMPL_INCLUDE),
                Chokepoints::Site.new(glob: BUDGET_DRIVER, permits: BUDGET_IMPL_INCLUDE),
                Chokepoints::Site.new(glob: BUDGET_IMPL, permits: BUDGET_RECORD_USE)],
        seed: { 'kernel/core/kalloc.c' => "#include \"erx/x.h\"\n  #  include \"budget_impl.h\"\nb->used++;\n",
                'kernel/core/budget_view.c' => "#include \"Budget_Impl.h\"\n",
                'fiasco/kernel/src/erx/budget.cpp' => "#include <kernel/core/budget_impl.h>\n",
                'fiasco/kernel/src/erx/erx_budget.h' => "struct erx_reserve { long charged; };\n",
                'fiasco/kernel/src/kern/erx_split.h' => "struct erx_reserve\n{\n\tlong charged;\n};\n",
                'kernel/core/watchdog.c' => "union erx_budget {\n\tint used;\n};\n",
                'kernel/core/budget.c' => "class erx_budget : base {};\n",
                'kernel/core/aligned.c' => "struct __attribute__((aligned(8))) erx_budget { int used; };\n",
                'kernel/core/split.c' => "struct\nerx_budget { int used; };\n",
                'kernel/core/after.c' => "struct erx_budget __attribute__((packed)) { int used; };\n",
                'kernel/core/macro.c' => "#define B erx_budget\nstruct B { int used; };\n",
                'fiasco/kernel/src/erx/qualified.cpp' => "struct alignas(8) ::erx_reserve { long charged; };\n",
                'fiasco/kernel/src/erx/final.cpp' => "struct erx_reserve final { long charged; };\n" }
      ),
      # A capability table's directory, counts, free list and emptied flag
      # are written only in kernel/core/cap.c (B4), by construction: its
      # record is defined only in the core's private header, and everywhere
      # else erx_cap_table_t is an incomplete type, so no file can write a
      # member or store a page of its own in the directory. This rule keeps
      # that header to the core and its host tests, and refuses any other
      # definition of the record. It reads the stopgap kernel's tree, glue
      # and inherited sources alike.
      Chokepoints::Forbidden.new(
        name: 'cap-table-private',
        rule: "only #{CAP_CORE} and its host tests include #{CAP_IMPL}, and no other file names " \
              'struct erx_cap_table but to refer to it',
        design: "#{KERNEL}#chokepoint-checks",
        scope: Chokepoints::Scope.new(own: true, extra: ['fiasco/kernel/**/*']),
        pattern: Regexp.union(CAP_IMPL_INCLUDE, record_use('erx_cap_table')),
        sites: [CAP_CORE, *host_tests(CAP_CORE)].map { |glob| Chokepoints::Site.new(glob: glob, permits: CAP_IMPL_INCLUDE) } +
               [Chokepoints::Site.new(glob: CAP_IMPL, permits: record_use('erx_cap_table'))],
        seed: { 'kernel/core/space.c' => "#include \"erx/cap.h\"\n#include \"cap_impl.h\"\n" \
                                         "void f(erx_cap_table_t *t, void *page) { t->pages[0] = page; }\n",
                'kernel/core/budget.c' => "#include <core/Cap_Impl.h>\n",
                'liberx/seeded.c' => "#include \"kernel/core/cap_impl.h\"\n",
                'fiasco/kernel/src/erx/cap.cpp' => "#include \"cap_impl.h\"\n",
                BUDGET_DRIVER => "#include \"cap_impl.h\"\n",
                'kernel/core/table.c' => "struct erx_cap_table {\n\tunsigned capacity;\n};\n",
                'include/erx/cap.h' => "struct erx_cap_table\n{\n\tunsigned capacity;\n};\n",
                'kernel/core/macro.c' => "#define T erx_cap_table\nstruct T { unsigned capacity; };\n",
                'fiasco/kernel/src/kern/table.cpp' => "struct alignas(8) erx_cap_table final { };\n",
                CAP_CORE => "union erx_cap_table { unsigned capacity; };\n" }
      ),
      # One rule for each layout the ABI file marks private.
      *PRIVATE_LAYOUTS.map { |layout| private_layout_rule(layout) },
      # erx_cap_slot_clear is named only in the cores, its declaration in
      # include/erx/cap.h and the core's host tests, so the call graph that
      # cap-slot-clear-callers reads sees every caller (K21, K25). It reads
      # the stopgap kernel's tree, glue and inherited sources alike.
      Chokepoints::Forbidden.new(
        name: 'cap-slot-clear-named',
        rule: 'only the cores, include/erx/cap.h and the capability core\'s host tests name erx_cap_slot_clear',
        design: "#{KERNEL}#chokepoint-checks",
        scope: Chokepoints::Scope.new(own: true, extra: ['fiasco/kernel/**/*']),
        pattern: CAP_SLOT_CLEAR,
        sites: ['kernel/core/*.c', 'include/erx/cap.h', *host_tests(CAP_CORE)].map { |glob| Chokepoints::Site.new(glob: glob) },
        seed: { 'include/erx/space.h' => "erx_status_t erx_cap_slot_clear(erx_cap_table_t *, erx_cap_t, uint64_t);\n",
                CAP_SLOT_IMPL => "static inline void f(void) { erx_cap_slot_clear(0, 0, 0); }\n",
                'test/fixtures/budget_driver.c' => "void f(void) { erx_cap_slot_clear(0, 0, 0); }\n",
                'fiasco/kernel/src/erx/cap.cpp' => "void f() { erx_cap_slot_clear(table, cap, object); }\n",
                'fiasco/kernel/src/kern/space.cpp' => "void f() { erx_cap_slot_clear(table, cap, 0); }\n" }
      ),
      # D3: a runtime reads a lane's ring only through erx_lane_take. A
      # file that cannot name the ring header, the record, the reader page
      # or where they sit in a side has no typed way to reach them, so this
      # text rule keeps every other typed reader out, the funnel's pure
      # check included. It reads erXos's own C, the imports below kernel/
      # included, the stopgap kernel's tree with its glue, and inherited
      # OTP and musl. It cannot see untyped pointer arithmetic on a side's
      # address (the reader record's side pointers, or the mapping that
      # produced them), nor a name a macro pastes together
      # (erx_lane_ ## hdr): those residuals are in TODO.md, for the
      # syntax-tree leg and for the reader owning the mapping.
      Chokepoints::Forbidden.new(
        name: 'lane-pages-reader',
        rule: "only #{LANE_READER}, whose erx_lane_take is the one reader of a lane's ring, names a lane's " \
              'shared layouts, their accessors or the offsets of a side (D3)',
        design: "#{DOMAINS}#the-funnel",
        scope: Chokepoints::Scope.new(own: true, extra: ['fiasco/kernel/**/*', *INHERITED_RUNTIME], except: [ASMJIT]),
        pattern: LANE_LAYOUT,
        sites: [LANE_READER, *ABI_C_OUTPUTS, *LANE_PRODUCERS].map { |path| Chokepoints::Site.new(glob: path) },
        seed: { 'liberx/erx_funnel.c' => "void f(void) { erx_lane_hdr_wpos_load(hdr, &wpos); }\n",
                'otp/erts/emulator/sys/erxos/erl_lane_drv.c' => "const erx_lane_rec_t *rec = ring;\n",
                'liberx/backend/hosted/peek.c' => "data = side + ERX_LANE_SIDE_DATA;\n",
                'liberx/erx_lane_peek.c' => "#define RING struct erx_lane_hdr\n" }
      ),
      Chokepoints::Forbidden.new(
        name: 'seam-only-from-glue',
        rule: "the glue alone of the stopgap kernel's sources includes erXos's headers",
        design: "#{STOPGAP}#interfaces",
        scope: Chokepoints::Scope.new(own: false, extra: ['fiasco/kernel/**/*'], except: [GLUE]),
        pattern: %r{#{INCLUDE}[<"]erx/}i,
        seed: { 'fiasco/kernel/src/kern/seeded.cpp' => "#include \"erx/core/watchdog.h\"\n" }
      )
    ].freeze

    # Rules read from the cores' call graph, which the stack proof builds at
    # every level it proves and checks against these before proving it.
    CALL_GRAPH = [
      # The one function that clears a capability slot is called only by a
      # close, a pass's take step and the emptying of a stopped space's
      # table (K21, K25); cap-slot-clear-named keeps every call to it inside
      # the cores, which this graph covers.
      Chokepoints::Callers.new(
        name: 'cap-slot-clear-callers',
        rule: 'only erx_cap_close, erx_pass_take and erx_space_clear_caps call erx_cap_slot_clear',
        design: "#{KERNEL}#chokepoint-checks",
        callee: 'erx_cap_slot_clear',
        callers: %w[erx_cap_close erx_pass_take erx_space_clear_caps],
        seed: { 'erx_cap_install' => 'call', 'erx_cap_reserve' => 'tail_jump', 'cap.o:erx_pass_take' => 'call' }
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
      liberx/backend/hosted/generated/calls.h liberx/elf_plan.c liberx/erx_lane.c liberx/generated/abi_reader.c
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
      # The core's own files are exempt: budget-records-private keeps their
      # records out of every other file until the syntax trees are read.
      Chokepoints::Pending.new(
        name: 'budget-counters', rule: "only erx_budget_adjust changes a budget's counters, and kernel memory " \
                                       'is allocated only through the budget-charging funnel (K3, K32)',
        design: "#{KERNEL}#chokepoint-checks",
        awaits: ['kernel/core/budget*', 'include/erx/core/budget*'],
        existing: ['kernel/core/budget.c', BUDGET_IMPL],
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

    ALL = (ACTIVE + CALL_GRAPH + ELSEWHERE + PENDING).freeze
  end
end
