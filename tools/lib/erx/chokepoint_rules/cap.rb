# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

module Erx
  module ChokepointRules
    # The capability core and the hand-written header of its table record.
    CAP_CORE = 'kernel/core/cap.c'
    CAP_IMPL = 'kernel/core/cap_impl.h'
    CAP_IMPL_INCLUDE = include_of(CAP_IMPL)
    # The one function that clears a slot, by its whole name; a name a macro
    # pastes together (erx_cap_slot_ ## clear) does not match.
    CAP_SLOT_CLEAR = /\berx_cap_slot_clear\b/
    # The capability slot's generated header, which the rules below name.
    CAP_SLOT_IMPL = ABI::Generated::SCHEMA.types.fetch('erx_cap_slot').private_header

    declare_group(
      private_headers: [CAP_IMPL],
      private_header_tests: host_tests(CAP_CORE),
      rules: [
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
                  'test/fixtures/budget_driver.c' => "#include \"cap_impl.h\"\n",
                  'kernel/core/table.c' => "struct erx_cap_table {\n\tunsigned capacity;\n};\n",
                  'include/erx/cap.h' => "struct erx_cap_table\n{\n\tunsigned capacity;\n};\n",
                  'kernel/core/macro.c' => "#define T erx_cap_table\nstruct T { unsigned capacity; };\n",
                  'fiasco/kernel/src/kern/table.cpp' => "struct alignas(8) erx_cap_table final { };\n",
                  CAP_CORE => "union erx_cap_table { unsigned capacity; };\n" }
        ),
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
          sites: ['kernel/core/*.c', 'include/erx/cap.h', *host_tests(CAP_CORE), *host_tests('kernel/core/delete.c')].map { |glob| Chokepoints::Site.new(glob: glob) },
          seed: { 'include/erx/space.h' => "erx_status_t erx_cap_slot_clear(erx_cap_table_t *, erx_cap_t, uint64_t);\n",
                  CAP_SLOT_IMPL => "static inline void f(void) { erx_cap_slot_clear(0, 0, 0); }\n",
                  'test/fixtures/budget_driver.c' => "void f(void) { erx_cap_slot_clear(0, 0, 0); }\n",
                  'fiasco/kernel/src/erx/cap.cpp' => "void f() { erx_cap_slot_clear(table, cap, object); }\n",
                  'fiasco/kernel/src/kern/space.cpp' => "void f() { erx_cap_slot_clear(table, cap, 0); }\n" }
        ),
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
        ),
        # A table receives capabilities in four ways only (K17): a copy is
        # installed only by erx_cap_dup and a fork's erx_space_copy, and a
        # creation's install only by the creation calls of the generated
        # dispatch, which the full kernel brings; until then no core installs
        # by kind, and a pass fills only through erx_pass_install.
        Chokepoints::Callers.new(
          name: 'cap-install-copy-callers',
          rule: 'only erx_cap_dup and erx_space_copy call erx_cap_install_copy',
          design: "#{KERNEL}#chokepoint-checks",
          callee: 'erx_cap_install_copy',
          callers: %w[erx_cap_dup erx_space_copy],
          seed: { 'erx_cap_pass' => 'call', 'erx_pass_install' => 'tail_jump', 'space.o:erx_space_create' => 'call' }
        ),
        Chokepoints::Callers.new(
          name: 'cap-install-kind-callers',
          rule: "no core calls erx_cap_install_kind until the generated dispatch's creation calls do",
          design: "#{KERNEL}#chokepoint-checks",
          callee: 'erx_cap_install_kind',
          callers: %w[],
          seed: { 'erx_cap_dup' => 'call', 'erx_space_copy' => 'tail_jump', 'cap.o:erx_pass_install' => 'call' }
        )
      ]
    )
  end
end
