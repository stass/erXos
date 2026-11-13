# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

module Erx
  module ChokepointRules
    # The device-tree reader is the one way into a tree (docs/design-device-tree.md,
    # "The reader"): outside the stopgap's own fiasco/ tree, only the reader and
    # erXos's kernel's own tree user include libfdt.h, so every other reader of a
    # tree goes through erx_dt_accept's checks.
    DT_CORE = 'kernel/core/dt.c'
    DT_KERNEL_FDT = 'kernel/platform/fdt.c'
    LIBFDT_INCLUDE = include_of('libfdt.h')

    declare_group(
      rules: [
        Chokepoints::Forbidden.new(
          name: 'dt-libfdt-includers',
          rule: "outside fiasco/, only #{DT_CORE} and #{DT_KERNEL_FDT} include libfdt.h",
          design: 'docs/design-device-tree.md#the-reader',
          scope: Chokepoints::Scope.new(own: true, except: ['fiasco/**']),
          pattern: LIBFDT_INCLUDE,
          sites: [DT_CORE, DT_KERNEL_FDT].map { |glob| Chokepoints::Site.new(glob: glob, permits: LIBFDT_INCLUDE) },
          seed: { 'liberx/dom.c' => "#include <libfdt.h>\n",
                  'kernel/core/page.c' => "#include \"contrib/LIBFDT.H\"\n",
                  'liberx/backend/fiasco/root_open.c' => "#include \"../../../fiasco/libfdt/lib/contrib/libfdt.h\"\n" }
        )
      ]
    )
  end
end
