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
        ),
        # The driver alone passes handles into a program's table
        # (docs/design-programs.md, "The channel"), each copy with the rights
        # the program core gives its index and none with DUP, GIVE or
        # DESTROY, so the session keeps the only DESTROY on what it made. A
        # pass anywhere else in ERTS would hand a program what that table
        # does not list.
        Chokepoints::Forbidden.new(
          name: 'program-installs',
          rule: "only #{PROGRAM_DRIVER} calls erx_cap_pass in ERTS",
          design: 'docs/design-programs.md#the-channel',
          scope: Chokepoints::Scope.new(own: false, extra: %w[otp/erts/**/*],
                                        except: ['otp/erts/emulator/asmjit/**/*']),
          pattern: /.*\berx_cap_pass\s*\(.*/,
          sites: [Chokepoints::Site.new(glob: PROGRAM_DRIVER)],
          seed: { 'otp/erts/emulator/sys/erxos/erx_gate.c' =>
                    "\t(void)erx_cap_pass(ERX_CAP_SELF, space, 1);\n" }
        ),
        # A frame from a program becomes a term in one place: the driver's
        # input task, by ERTS's decoder with ERTS_DIST_EXT_BTT_SAFE, which
        # refuses an atom the runtime does not hold instead of making it
        # (docs/design-abi.md, "Program protocol", Atoms). Stock ERTS's own
        # decodes (binary_to_term, distribution) are outside erXos's sources
        # and keep their own flags. Any mention of the decoder outside the
        # driver is refused, and in the driver a line must hold one call that
        # names the flag, unnegated, before the call's end, so a call split
        # across lines is refused too. With no decode in the driver the rule
        # holds with no site.
        Chokepoints::Forbidden.new(
          name: 'program-safe-decode',
          rule: "only #{PROGRAM_DRIVER} calls erts_decode_ext in erXos's ERTS sources, " \
                'and only with ERTS_DIST_EXT_BTT_SAFE in the call',
          design: 'docs/design-abi.md#program-protocol',
          scope: Chokepoints::Scope.new(own: false, extra: %w[otp/erts/emulator/sys/erxos/**/*
                                                              otp/erts/emulator/nifs/erxos/**/*
                                                              otp/erts/**/erx_*]),
          pattern: /.*\berts_decode_ext\b.*/,
          sites: [Chokepoints::Site.new(glob: PROGRAM_DRIVER,
                                        permits: /\A(?!.*\berts_decode_ext\b.*\berts_decode_ext\b)
                                              .*\berts_decode_ext\s*\([^;~]*\bERTS_DIST_EXT_BTT_SAFE\b.*\z/x)],
          seed: { 'otp/erts/emulator/sys/erxos/erx_lane_drv.c' =>
                    "\tterm = erts_decode_ext(&factory, &bytes, ERTS_DIST_EXT_BTT_SAFE);\n",
                  PROGRAM_DRIVER => "\tterm = erts_decode_ext(&factory, &bytes, 0);\n" }
        )
      ]
    )
  end
end
