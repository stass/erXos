# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

module Erx
  module ChokepointRules
    # The erx_program port driver, ERTS's one maker of a program's spaces.
    PROGRAM_DRIVER = 'otp/erts/emulator/sys/erxos/erx_program_drv.c'

    declare_group(
      rules: [
        # The driver makes every kernel call about a program
        # (docs/design-runtime.md, "Programs as ports"), each step as the
        # program core orders it, so a start undoes exactly what it made and
        # an end releases it once. A space, an image's mapping, a thread
        # made with erx_thread_create (ERTS's own threads come from musl's
        # pthread_create, outside this scope), or a stop of a space other
        # than the runtime's own (erx_crash_area.c's) anywhere else in ERTS
        # is outside that order.
        Chokepoints::Forbidden.new(
          name: 'program-spaces',
          rule: "only #{PROGRAM_DRIVER} calls erx_space_create, erx_image_map and erx_thread_create, " \
                'and erx_space_stop on a space other than ERX_CAP_SELF, in ERTS',
          design: 'docs/design-runtime.md#programs-as-ports',
          scope: Chokepoints::Scope.new(own: false, extra: %w[otp/erts/**/*],
                                        except: ['otp/erts/emulator/asmjit/**/*']),
          pattern: /.*(?:\b(?:erx_space_create|erx_image_map|erx_thread_create)\s*\(|
                      \berx_space_stop\s*\((?!\s*ERX_CAP_SELF\s*,)).*/x,
          sites: [Chokepoints::Site.new(glob: PROGRAM_DRIVER)],
          seed: { 'otp/erts/emulator/sys/erxos/erx_gate.c' =>
                    "\t(void)erx_space_create(0, ERX_CAP_SELF, gate, 2, 0, 16, &space);\n",
                  'otp/erts/emulator/nifs/erxos/erx_domain_lib_nif.c' =>
                    "\t(void)erx_space_stop(space, 0);\n" }
        )
      ]
    )
  end
end
