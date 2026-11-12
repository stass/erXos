# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

module Erx
  module ChokepointRules
    # liberx's program layer, the code a program runs before and around its
    # main (docs/design-programs.md#the-startup-message).
    declare_group(
      rules: [
        # The program layer sits above the kernel interface, as a service
        # does: the backend's task entry calls into it, and it reaches the
        # kernel only through liberx's erx_ calls, so erXos's own kernel
        # replaces the backend under it and nothing in it moves.
        Chokepoints::Forbidden.new(
          name: 'program-layer-above-the-backend',
          rule: "liberx's program layer (liberx/program/) names no erx_fiasco_ symbol",
          design: 'docs/design-programs.md#verification-and-testing',
          scope: Chokepoints::Scope.new(own: false, extra: ['liberx/program/**/*']),
          pattern: /\berx_fiasco_\w*/,
          seed: { 'liberx/program/seeded.c' => "void f(void) { erx_fiasco_libc_start(0); }\n" }
        )
      ],
      unchecked_objects: %w[liberx/program/startup.c liberx/program/startup.h]
    )
  end
end
