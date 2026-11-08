/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

/*
 * The calls the call table refuses on both backends (docs/design-stopgap.md, "The
 * call table"), in one place so a caller cannot come to depend on one that only
 * one backend has.
 */

#include <stdint.h>

#include "erx/abi.h"
#include "liberx/backend/api.h"

int
erx_thread_stop(uint64_t thread)
{
	(void)thread;
	return (ERX_ENOTSUP);
}

int
erx_thread_read(uint64_t thread)
{
	(void)thread;
	return (ERX_ENOTSUP);
}

int
erx_thread_write(uint64_t thread)
{
	(void)thread;
	return (ERX_ENOTSUP);
}

int
erx_thread_set_urgency(uint64_t thread, uint64_t urgency)
{
	(void)thread;
	(void)urgency;
	return (ERX_ENOTSUP);
}

int
erx_irq_route(uint64_t irq, uint64_t cpu)
{
	(void)irq;
	(void)cpu;
	return (ERX_ENOTSUP);
}

int
erx_ipc_call(uint64_t gate, uint64_t tag, uint64_t send_by, uint64_t reply_by)
{
	(void)gate;
	(void)tag;
	(void)send_by;
	(void)reply_by;
	return (ERX_ENOTSUP);
}

int
erx_ipc_send(uint64_t gate, uint64_t tag, uint64_t send_by)
{
	(void)gate;
	(void)tag;
	(void)send_by;
	return (ERX_ENOTSUP);
}

int
erx_ipc_reply(uint64_t tag)
{
	(void)tag;
	return (ERX_ENOTSUP);
}

int
erx_ipc_reply_wait(uint64_t tag, uint64_t wait_by)
{
	(void)tag;
	(void)wait_by;
	return (ERX_ENOTSUP);
}

int
erx_trace_read(uint64_t res, uint32_t cpu, uint64_t cursor, erx_trace_record_t *records, uint32_t max,
    erx_trace_read_result_t *result)
{
	(void)res;
	(void)cpu;
	(void)cursor;
	(void)records;
	(void)max;
	(void)result;
	return (ERX_ENOTSUP);
}
