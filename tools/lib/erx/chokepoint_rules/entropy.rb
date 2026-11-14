# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

module Erx
  module ChokepointRules
    # erx_entropy_read leaves the generator's bytes in the caller's UTCB;
    # erx_entropy_take reads, moves the bytes out and zeroes the words that
    # held them (docs/design-stopgap.md, "The call table"). The read is
    # declared only in its private header, so a caller that names it
    # without the header fails to build (test/host/hosted_function_api_test.rb).
    # This rule covers what the header cannot: an include of it, or a
    # declaration of the read written by hand. The backends define the
    # read, and the function-API set tests it. The symbol stays global, so
    # a name pasted together (erx_entropy_ ## read) or a Mach-O asm label
    # ("_erx_entropy_read") gets past both; ERTS's imports
    # (otp/erts/emulator/sys/erxos/imports.txt) list only the take.
    ENTROPY_TAKE = 'liberx/backend/core/entropy_take.c'
    ENTROPY_READ = 'liberx/backend/core/entropy_read.h'

    declare_group(
      unchecked_objects: [ENTROPY_TAKE, ENTROPY_READ],
      rules: [
        Chokepoints::Forbidden.new(
          name: 'entropy-take',
          rule: 'only erx_entropy_take calls erx_entropy_read, so every caller of the generator gets its bytes ' \
                'out of the UTCB with the words that held them zeroed',
          design: "#{STOPGAP}#the-call-table",
          scope: Chokepoints::Scope.new(own: true, extra: [GLUE, 'otp/**/*', 'musl/**/*'],
                                        except: ['otp/erts/emulator/asmjit/**/*']),
          pattern: Regexp.union(/\berx_entropy_read\b/, include_of(ENTROPY_READ)),
          sites: [ENTROPY_READ, ENTROPY_TAKE, 'liberx/backend/fiasco/service_stubs.c', 'liberx/backend/hosted/vm.c',
                  'test/guest/function_api/cases.c'].map { |glob| Chokepoints::Site.new(glob: glob) },
          seed: { 'musl/src/internal/erxos/syscall.c' => "int erx_entropy_read(unsigned);\n",
                  'otp/erts/emulator/beam/erl_bif_unique.c' => "int f(void) { return erx_entropy_read(16); }\n",
                  'liberx/backend/fiasco/libc_start.c' => "#include \"core/ENTROPY_READ.H\"\n" }
        )
      ]
    )
  end
end
