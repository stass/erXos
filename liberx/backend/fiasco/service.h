/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

#ifndef ERX_FIASCO_SERVICE_H
#define ERX_FIASCO_SERVICE_H

#include <stddef.h>
#include <stdint.h>

#include "erx/abi.h"
#include "erx/cdefs.h"
#include "erx/core/crash.h"

/*
 * The root service (docs/design-stopgap.md, "The root service"): one thread that
 * owns the root's tables and receives every request and every fault of the root's
 * threads through one gate.
 */

/*
 * The root's first steps, on its first thread: maps its image, touches each page
 * of the archive so it maps read-only, builds the pool and thread table, starts
 * the service and makes it this thread's pager. From its return every fault of a
 * root thread ends the machine. Returns NULL, or why the boot cannot go on.
 */
const char	*erx_fiasco_root_up(const void *archive, size_t archive_bytes);

/*
 * Sends one request of bytes to the service and waits for its reply. Returns the
 * reply's status, with *reply holding the rest.
 */
uint64_t	erx_fiasco_service_gate(void);
int	erx_fiasco_service_call(uint32_t number, const void *request, size_t bytes,
	    erx_fiasco_reply_t *reply);

/* how is ERX_END_OFF or ERX_END_RESET; res is ignored. Returns only on a refusal. */
int	erx_machine_end(uint64_t res, uint32_t how);

/*
 * The end path (docs/design-stopgap.md, "The end path"): the first caller wins
 * and the rest sleep. With a fault it first prints the crash frame. Takes no lock.
 */
_Noreturn void	erx_fiasco_end(const erx_crash_fault_t *fault, uint32_t how);

#ifdef ERX_FIASCO_TEST_HOOKS
#include <stdatomic.h>
#include <stdbool.h>

/* See service.c: the start step to fail, and whether a thread's capabilities are gone. */
extern _Atomic uint32_t erx_fiasco_test_start_fails;
bool erx_fiasco_test_thread_caps_gone(uint32_t);
#endif

#endif /* ERX_FIASCO_SERVICE_H */
