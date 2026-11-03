// Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
// SPDX-License-Identifier: BSD-2-Clause
//
// The link probe of erXos's C17 cores (docs/design-stopgap.md,
// "Interfaces", Build): one call from the kernel's C++ into the cores'
// archive, which erXos's LLVM build compiles and the kernel link takes
// from ERX_CORE_ARCHIVE. The boot prints the result, and the boot
// transcript (tools/lib/erx/qemu.rb) requires the line, so a kernel whose
// link dropped the archive, or whose call did not reach the core, fails
// the boot test.
INTERFACE:

#include "initcalls.h"

class Erx_probe
{
};

IMPLEMENTATION:

#include <cstdio>
#include "erx/core/watchdog.h"

PUBLIC static FIASCO_INIT
void
Erx_probe::run()
{
  static char const value[] = "2,5,60";
  erx_watchdog_config_t config = erx_watchdog_config_default();
  erx_watchdog_parse_status_t status
    = erx_watchdog_parse(value, sizeof(value) - 1, &config);
  printf("erx: C17 core probe: erx.watchdog=%s is %s: %u,%u,%u\n", value,
         erx_watchdog_parse_reason(status), config.period_s,
         config.deadline_s, config.boot_s);
}
