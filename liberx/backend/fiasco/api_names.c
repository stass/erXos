/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

/*
 * The function API's names (liberx/backend/api.h) over this backend's, for the calls
 * whose native spelling says Fiasco. Including that header with this backend's own
 * makes a compiler check that the two agree on every call both declare.
 */

#include <stddef.h>
#include <stdint.h>

#include "erx/abi.h"
#include "liberx/backend/api.h"
#include "liberx/backend/fiasco/log.h"
#include "liberx/backend/fiasco/park.h"
#include "liberx/backend/fiasco/service.h"
#include "liberx/backend/fiasco/thread.h"
#include "liberx/backend/fiasco/umtx.h"
#include "liberx/backend/fiasco/vm.h"

_Static_assert(sizeof(erx_thread_start_t) == sizeof(erx_fiasco_start_t), "one start record");
_Static_assert(offsetof(erx_thread_start_t, tls) == offsetof(erx_fiasco_start_t, tls), "one start record");
_Static_assert(ERX_WAIT_FOREVER == ERX_FIASCO_UMTX_FOREVER, "one deadline meaning none");
_Static_assert(ERX_NO_EXECUTOR_SLOT == ERX_BACKEND_PARK_NO_SLOT, "one answer on a worker");

uint64_t
erx_vm_free_pages(void)
{
	return (erx_fiasco_vm_free_pages());
}

uint64_t
erx_clock_ns(void)
{
	return (erx_fiasco_clock_ns());
}

uint64_t
erx_thread_pointer(void)
{
	return (erx_fiasco_thread_pointer());
}

int
erx_thread_set_clear_word(uint64_t thread, uint64_t word)
{
	return (erx_fiasco_thread_set_clear_word(thread, word));
}

const erx_group_stat_t *
erx_group_status(void)
{
	return (erx_fiasco_group_status());
}

uint32_t
erx_executor_slot(void)
{
	return (erx_fiasco_thread_self()->executor_slot);
}

void
erx_group_trigger(void)
{
	erx_fiasco_group_trigger();
}
