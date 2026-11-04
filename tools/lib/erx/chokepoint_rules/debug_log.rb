# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

module Erx
  module ChokepointRules
    # A rendered log line reaches a console through one call, so no other core
    # code writes bytes there; the hosts that provide the effect are listed.
    declare_group(
      rules: [
        Chokepoints::Forbidden.new(
          name: 'dispatch-console-write',
          rule: 'among the cores only the debug-log handler writes to the early console, and only its hosts provide the write',
          design: "#{KERNEL}#console-log-and-panic",
          scope: ERXOS_C,
          pattern: /\berx_effect_console_write\b/,
          sites: [Chokepoints::Site.new(glob: 'kernel/core/debug_log.c'),
                  Chokepoints::Site.new(glob: 'include/erx/core/effects.h'),
                  Chokepoints::Site.new(glob: 'fiasco/kernel/src/erx/erx_syscall.cpp'),
                  Chokepoints::Site.new(glob: 'liberx/backend/hosted/log.c'),
                  Chokepoints::Site.new(glob: 'test/fixtures/dispatch_driver.c'),
                  Chokepoints::Site.new(glob: 'tools/fuzz/dispatch_fuzz.c')],
          seed: { 'kernel/core/seeded.c' => "void f(void) { erx_effect_console_write(\"x\", 1); }\n" }
        )
      ]
    )
  end
end
