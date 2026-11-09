/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

/*
 * A root built with nothing to run, as the boot suite's is: it has checked the handoff and
 * the archive, says so, and ends the machine.
 */

#include "erx/abi.h"
#include "liberx/backend/fiasco/console.h"
#include "liberx/backend/fiasco/runtime_entry.h"
#include "liberx/backend/fiasco/service.h"

static const char line[] = "erx: root task: this image holds no program\n";

const char *
erx_fiasco_program_start(const erx_boot_handoff_view_t *handoff, const erx_manifest_view_t *manifest,
    const erx_pack_view_t *pack, const erx_boot_args_t *boot_args)
{
	(void)handoff;
	(void)manifest;
	(void)pack;
	(void)boot_args;
	erx_fiasco_console_write(line, sizeof(line) - 1);
	(void)erx_machine_end(0, ERX_END_OFF);
	return ("the service refused the machine's end");
}
