# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

module Erx
  module ChokepointRules
    # The object store's private header, which only the store and its host
    # tests include.
    OBJECT_CORE = 'kernel/core/object.c'
    OBJECT_IMPL = 'kernel/core/object_impl.h'
    OBJECT_IMPL_INCLUDE = include_of(OBJECT_IMPL)
    OBJECT_RECORD_USE = record_use('erx_object', 'erx_object_store')
    # The two functions that write an object's state word, by their whole
    # names; a name a macro pastes together gets past them.
    OBJECT_CAP_REMOVE = /\berx_object_cap_remove\b/
    OBJECT_CLOSE = /\berx_object_close\b/

    declare_group(
      private_headers: [OBJECT_IMPL],
      private_header_tests: host_tests(OBJECT_CORE),
      rules: [
        # An object's header is written only in kernel/core/object.c (K21,
        # K26): its record is defined only in the store's private header,
        # which only the store and its host tests include, and every other
        # file names the tag only to refer to it, so no other code writes a
        # header's state, counts or slot list. It reads the stopgap kernel's
        # tree, glue and inherited sources alike.
        Chokepoints::Forbidden.new(
          name: 'object-records-private',
          rule: "only #{OBJECT_CORE} and its host tests include #{OBJECT_IMPL}, and no other file " \
                'names struct erx_object or struct erx_object_store but to refer to it',
          design: "#{KERNEL}#chokepoint-checks",
          scope: Chokepoints::Scope.new(own: true, extra: ['fiasco/kernel/**/*']),
          pattern: Regexp.union(OBJECT_IMPL_INCLUDE, OBJECT_RECORD_USE),
          sites: [OBJECT_CORE, *host_tests(OBJECT_CORE)].map { |glob| Chokepoints::Site.new(glob: glob, permits: OBJECT_IMPL_INCLUDE) } +
                 [Chokepoints::Site.new(glob: OBJECT_IMPL, permits: OBJECT_RECORD_USE)],
          seed: { 'kernel/core/cap.c' => "#include \"erx/cap.h\"\n#include \"object_impl.h\"\n",
                  'kernel/core/attach.c' => "#include <core/Object_Impl.h>\n",
                  'test/fixtures/cap_driver.c' => "#include \"object_impl.h\"\n",
                  'fiasco/kernel/src/erx/object.cpp' => "#include <kernel/core/object_impl.h>\n",
                  'kernel/core/delete.c' => "struct erx_object {\n\tunsigned state;\n};\n",
                  'kernel/core/split.c' => "struct\nerx_object_store { unsigned long next; };\n",
                  'kernel/core/macro.c' => "#define O erx_object\nstruct O { unsigned state; };\n",
                  'include/erx/object.h' => "union erx_object { unsigned state; };\n",
                  'fiasco/kernel/src/kern/object.cpp' => "struct alignas(8) erx_object final { };\n" }
        ),
        # The two writers of the state word are named only in the store, its
        # header and its host tests, and each in the one core that calls it,
        # so the call graph the rules below read sees every caller. It reads
        # the stopgap kernel's tree, glue and inherited sources alike.
        Chokepoints::Forbidden.new(
          name: 'object-state-writers-named',
          rule: "only #{OBJECT_CORE}, include/erx/object.h and the store's host tests name " \
                'erx_object_cap_remove and erx_object_close, kernel/core/cap.c names the first and ' \
                'kernel/core/delete.c the second',
          design: "#{KERNEL}#chokepoint-checks",
          scope: Chokepoints::Scope.new(own: true, extra: ['fiasco/kernel/**/*']),
          pattern: Regexp.union(OBJECT_CAP_REMOVE, OBJECT_CLOSE),
          sites: [OBJECT_CORE, 'include/erx/object.h', *host_tests(OBJECT_CORE)].map { |glob| Chokepoints::Site.new(glob: glob) } +
                 [Chokepoints::Site.new(glob: 'kernel/core/cap.c', permits: OBJECT_CAP_REMOVE),
                  Chokepoints::Site.new(glob: 'kernel/core/delete.c', permits: OBJECT_CLOSE)],
          seed: { 'kernel/core/attach.c' => "(void)erx_object_cap_remove(object);\n",
                  'kernel/core/cap.c' => "(void)erx_object_close(object);\n",
                  'kernel/core/delete.c' => "(void)erx_object_cap_remove(object);\n",
                  'include/erx/cap.h' => "bool erx_object_close(erx_object_t *);\n",
                  'test/fixtures/cap_driver.c' => "(void)erx_object_cap_remove(o);\n",
                  'fiasco/kernel/src/erx/object.cpp' => "void f() { erx_object_close(o); }\n" }
        ),
        # The state word becomes RELEASED only when erx_cap_slot_clear takes
        # the slot count to zero (K21): the one function that clears a slot
        # is the one that counts it out.
        Chokepoints::Callers.new(
          name: 'object-release-callers',
          rule: 'only erx_cap_slot_clear calls erx_object_cap_remove',
          design: "#{KERNEL}#chokepoint-checks",
          callee: 'erx_object_cap_remove',
          callers: %w[erx_cap_slot_clear],
          seed: { 'erx_cap_close' => 'call', 'erx_pass_take' => 'tail_jump', 'object.o:release_now' => 'call' }
        ),
        # An object is closed, its state word made DELETED, only by the
        # deletion core's step (K21, K26), whose result decides which destroy
        # goes on.
        Chokepoints::Callers.new(
          name: 'object-close-callers',
          rule: 'only erx_delete_step calls erx_object_close',
          design: "#{KERNEL}#chokepoint-checks",
          callee: 'erx_object_close',
          callers: %w[erx_delete_step],
          seed: { 'erx_cap_slot_clear' => 'call', 'erx_object_cap_remove' => 'tail_jump',
                  'delete.o:close_now' => 'call' }
        )
      ]
    )
  end
end
