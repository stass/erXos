# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

module Erx
  module ChokepointRules
    # The root's machine calls answered in the root (the kernel's log and trace rings) take
    # the root resource's slot as their resource. Fiasco's backend does not check it, so a
    # literal 0 builds and runs there, and fails only on erXos's kernel, which checks the
    # capability (docs/design-fiasco.md, "The kernel's trace rings", "Reading").
    declare_group(
      rules: [
        Chokepoints::Forbidden.new(
          name: 'root-calls-name-the-root-resource',
          rule: 'a call of erx_trace_read, erx_log_read or erx_log_take names ERX_ROOT_SLOT_ROOT_RESOURCE, never the literal 0',
          design: 'docs/design-fiasco.md#the-kernels-trace-rings',
          scope: Chokepoints::Scope.new(own: true, extra: ['otp/erts/emulator/nifs/erxos/**/*']),
          pattern: /\berx_(?:trace_read|log_read|log_take)\(\s*0\s*,/,
          sites: [],
          seed: { 'otp/erts/emulator/nifs/erxos/erx_log_nif.c' =>
                    "static int f(void *w, uint64_t *r) { return (erx_log_take(0, w, 8, r)); }\n" }
        )
      ]
    )
  end
end
