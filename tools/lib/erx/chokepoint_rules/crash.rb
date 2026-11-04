# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

module Erx
  module ChokepointRules
    CRASH_CORE = 'kernel/core/crash.c'

    declare_group(
      rules: [
        # A binding's end funnel adds itself here, as the one caller the kernel has.
        Chokepoints::Forbidden.new(
          name: 'crash-record-writer',
          rule: "only #{CRASH_CORE} builds a crash record, through erx_crash_record_write, so every record the kernel " \
                'writes passed the rules the check holds it to',
          design: "#{KERNEL}#chokepoint-checks",
          scope: ERXOS_C,
          pattern: /\b(?:erx_crash_record_write|ERX_CRASH_MAGIC)\b/,
          sites: [Chokepoints::Site.new(glob: CRASH_CORE),
                  Chokepoints::Site.new(glob: 'include/erx/core/crash.h', permits: /\Aerx_crash_record_write\z/),
                  Chokepoints::Site.new(glob: 'include/erx/abi.h', permits: /\AERX_CRASH_MAGIC\z/),
                  Chokepoints::Site.new(glob: 'liberx/backend/fiasco/end.c', permits: /\Aerx_crash_record_write\z/),
                  Chokepoints::Site.new(glob: 'test/fixtures/crash_driver.c', permits: /\Aerx_crash_record_write\z/),
                  Chokepoints::Site.new(glob: 'tools/fuzz/crash_fuzz.c')],
          seed: { 'kernel/core/seeded.c' => "void f(void *b) { erx_crash_record_write(0, b, 0); }\n",
                  'fiasco/kernel/src/erx/seeded.cpp' => "unsigned long long m = ERX_CRASH_MAGIC;\n" }
        )
      ]
    )
  end
end
