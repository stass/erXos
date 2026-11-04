# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

module Erx
  module ChokepointRules
    # The kernel call's one funnel: a handler runs only through the admission
    # of kernel/core/dispatch.c, so no path reaches one undecoded.
    declare_group(
      private_headers: %w[kernel/core/dispatch_impl.h],
      private_header_tests: [],
      rules: [
        Chokepoints::Forbidden.new(
          name: 'dispatch-one-run',
          rule: 'only the dispatch runs a handler, and only the generated run table names one',
          design: "#{KERNEL}#system-call-dispatch",
          scope: ERXOS_C,
          pattern: /\berx_sys_(?:run|debug_log)\b/,
          sites: [Chokepoints::Site.new(glob: 'kernel/core/dispatch.c', permits: /\Aerx_sys_run\z/),
                  Chokepoints::Site.new(glob: 'kernel/core/debug_log.c', permits: /\Aerx_sys_debug_log\z/),
                  Chokepoints::Site.new(glob: 'kernel/generated/abi_calls.h'),
                  Chokepoints::Site.new(glob: 'kernel/generated/abi_run.c')],
          seed: { 'fiasco/kernel/src/erx/seeded.cpp' => "void f() { erx_sys_debug_log(0, 0); }\n",
                  'kernel/core/seeded.c' => "void f(void) { erx_sys_run(0, 0); }\n" }
        ),
        # A second caller could name another space's number and rate state.
        Chokepoints::Forbidden.new(
          name: 'dispatch-one-caller',
          rule: 'each kernel has one trap handler, the one code that names the caller of erx_dispatch',
          design: "#{KERNEL}#system-call-dispatch",
          scope: ERXOS_C,
          pattern: /\berx_dispatch\b/,
          sites: [Chokepoints::Site.new(glob: 'kernel/core/dispatch.c'),
                  Chokepoints::Site.new(glob: 'kernel/core/dispatch_impl.h'),
                  Chokepoints::Site.new(glob: 'include/erx/core/dispatch.h'),
                  Chokepoints::Site.new(glob: 'fiasco/kernel/src/erx/erx_syscall.cpp'),
                  Chokepoints::Site.new(glob: 'liberx/backend/hosted/log.c'),
                  Chokepoints::Site.new(glob: 'test/fixtures/dispatch_driver.c'),
                  Chokepoints::Site.new(glob: 'tools/fuzz/dispatch_fuzz.c')],
          seed: { 'fiasco/kernel/src/erx/seeded.cpp' => "void f() { erx_dispatch(0, 0, 0, 0); }\n" }
        ),
        # nm cannot see an inline read, so the source says what the glue may not do.
        Chokepoints::Forbidden.new(
          name: 'glue-reads-no-utcb',
          rule: 'the glue reads no UTCB field and no user address of a UTCB: it hands the cores the kernel mapping',
          design: "#{STOPGAP}#transport",
          scope: Chokepoints::Scope.new(own: false, extra: [GLUE]),
          pattern: /->\s*(?:values|buffers|buf_desc|utcb_addr|error)\b|\.(?:access|usr)\s*\(/,
          seed: { 'fiasco/kernel/src/erx/seeded.cpp' => "void f(T *t) { t->utcb().access()->values[0]; }\n" }
        )
      ]
    )
  end
end
