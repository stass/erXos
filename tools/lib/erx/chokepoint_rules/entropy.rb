# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

module Erx
  module ChokepointRules
    # erx_entropy_read leaves the generator's bytes in the caller's UTCB.
    # erx_entropy_take reads, moves the bytes out and zeroes the words that
    # held them, so with it the only caller no key stays behind in a UTCB
    # (docs/design-stopgap.md, "The call table"). The backends define the
    # read, liberx's header declares it, and the function-API set tests it.
    ENTROPY_TAKE = 'liberx/backend/core/entropy_take.c'

    declare_group(
      unchecked_objects: [ENTROPY_TAKE],
      rules: [
        Chokepoints::Forbidden.new(
          name: 'entropy-take',
          rule: 'only erx_entropy_take calls erx_entropy_read, so every caller of the generator gets its bytes ' \
                'out of the UTCB with the words that held them zeroed',
          design: "#{STOPGAP}#the-call-table",
          scope: Chokepoints::Scope.new(own: true, extra: [GLUE, 'otp/**/*', 'musl/**/*'],
                                        except: ['otp/erts/emulator/asmjit/**/*']),
          pattern: /\berx_entropy_read\b/,
          sites: [Chokepoints::Site.new(glob: ENTROPY_TAKE),
                  Chokepoints::Site.new(glob: 'liberx/backend/api.h'),
                  Chokepoints::Site.new(glob: 'liberx/backend/fiasco/service_stubs.c'),
                  Chokepoints::Site.new(glob: 'liberx/backend/hosted/vm.c'),
                  Chokepoints::Site.new(glob: 'test/guest/function_api/cases.c')],
          seed: { 'musl/src/internal/erxos/syscall.c' => "long f(void) { return erx_entropy_read(16); }\n",
                  'musl/src/linux/getrandom.c' => "long f(void) { return erx_entropy_read(16); }\n",
                  'otp/erts/emulator/beam/erl_bif_unique.c' => "int f(void) { return erx_entropy_read(16); }\n",
                  'liberx/backend/fiasco/libc_start.c' => "int f(void) { return erx_entropy_read(16); }\n" }
        )
      ]
    )
  end
end
