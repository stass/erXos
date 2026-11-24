/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

/*
 * The kernel's log object, as the root task holds it from the start
 * (docs/design-fiasco.md, "Boot handoff"). Bytes go out as given: text
 * attributed to a source is escaped by its caller before it gets here, and a
 * program's own output is not filtered.
 */

#include <l4/sys/consts.h>
#include <l4/sys/ipc.h>
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

bool
erx_fiasco_console_take(erx_console_reply_words_t *words)
{
	l4_msg_regs_t *const mr = l4_utcb_mr();
	l4_msgtag_t tag;

	mr->mr[0] = ERX_CONSOLE_RING_OP_TAKE;
	tag = l4_ipc_call(L4_BASE_LOG_CAP, l4_utcb(), l4_msgtag(L4_PROTO_LOG, 1, 0, 0), L4_IPC_NEVER);
	if (l4_error(tag) != 0)
		return (false);
	words->count = l4_msgtag_words(tag);
	for (size_t at = 0; at < words->count; at++)
		words->words[at] = mr->mr[at];
	return (true);
}

/* A close the kernel refuses changes nothing the caller could act on, so it reports nothing. */
void
erx_fiasco_console_close(void)
{
	l4_utcb_mr()->mr[0] = ERX_CONSOLE_RING_OP_CLOSE;
	(void)l4_ipc_call(L4_BASE_LOG_CAP, l4_utcb(), l4_msgtag(L4_PROTO_LOG, 1, 0, 0), L4_IPC_NEVER);
}

_Noreturn void
erx_fiasco_sleep_forever(void)
{
	for (;;)
		(void)l4_ipc_sleep(L4_IPC_NEVER);
}
