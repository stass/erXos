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
