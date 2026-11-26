# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

module Erx
  module ChokepointRules
    # The kernel's trace rings have one writer, so a write reaches nothing outside them and
    # each CPU writes only its own ring (docs/design-fiasco.md, "The kernel's trace rings").
    declare_group(
      rules: [
        Chokepoints::Forbidden.new(
          name: 'trace-rings-array',
          rule: 'only the kernel\'s rings\' core names their array; everything else reaches them through its functions',
          design: 'docs/design-fiasco.md#the-kernels-trace-rings',
          scope: ERXOS_C,
          pattern: /\berx_trace_rings\b/,
          sites: [Chokepoints::Site.new(glob: 'kernel/core/trace_rings.c')],
          seed: { 'kernel/core/seeded.c' => "extern char erx_trace_rings[];\nchar f(void) { return erx_trace_rings[0]; }\n" }
        ),
        Chokepoints::Forbidden.new(
          name: 'trace-kernel-writer',
          rule: 'only the trace glue\'s one writer, Erx_trace::record, writes on the kernel\'s rings',
          design: 'docs/design-fiasco.md#the-kernels-trace-rings',
          scope: ERXOS_C,
          pattern: /\berx_trace_kernel_put\b/,
          sites: [Chokepoints::Site.new(glob: 'kernel/core/trace_rings.c'),
                  Chokepoints::Site.new(glob: 'include/erx/core/trace_kernel.h'),
                  Chokepoints::Site.new(glob: 'fiasco/kernel/src/erx/erx_trace.cpp'),
                  Chokepoints::Site.new(glob: 'test/fixtures/trace_rings_driver.c')],
          seed: { 'fiasco/kernel/src/erx/erx_machine_stop.cpp' =>
                    "static void f(erx_trace_entry_t const *e) { erx_trace_kernel_put(0, e); }\n" }
        )
      ]
    )
  end
end
