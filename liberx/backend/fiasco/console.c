/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

/*
 * The kernel's log object and platform control object, as the root task holds
 * them from the start (docs/design-stopgap.md, "Boot handoff"). Text reaches
 * erx_fiasco_console_write from code that has already escaped what is not its
 * own, so bytes go out as given.
 */

#include <l4/sys/consts.h>
#include <l4/sys/ipc.h>
#include <l4/sys/platform_control.h>
#include <l4/sys/vcon.h>

#include "liberx/backend/fiasco/console.h"

/*
 * Writes one call's worth at a time. A console that fails drops the rest, as
 * the kernel's early console drops a byte its UART will not take: the caller's
 * result never depends on the console.
 */
void
erx_fiasco_console_write(const char *text, size_t length)
{
	size_t chunk;

	while (length > 0) {
		chunk = length < L4_VCON_WRITE_SIZE ? length : L4_VCON_WRITE_SIZE;
		if (l4_vcon_write(L4_BASE_LOG_CAP, text, (unsigned)chunk) < 0)
			return;
		text += chunk;
		length -= chunk;
	}
}

/*
 * The machine's end, which under -no-reboot QEMU turns into its own exit,
 * whichever is asked. A kernel that returns from the call has no way to do it,
 * so the thread sleeps and the harness's deadline reports the boot as hung.
 */
_Noreturn void
erx_fiasco_machine_end(bool reboot)
{
	(void)l4_platform_ctl_system_shutdown(L4_BASE_ICU_CAP, reboot ? 1 : 0);
	erx_fiasco_sleep_forever();
}

_Noreturn void
erx_fiasco_machine_off(void)
{
	erx_fiasco_machine_end(false);
}

_Noreturn void
erx_fiasco_sleep_forever(void)
{
	for (;;)
		(void)l4_ipc_sleep(L4_IPC_NEVER);
}
