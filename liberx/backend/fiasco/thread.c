/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

/*
 * The caller's side of thread creation: the record table and the claim, which
 * run in the calling thread under the thread lock, and the requests to the
 * service, which alone calls the kernel about a thread.
 */

#include <stdatomic.h>
#include <stddef.h>
#include <stdint.h>

#include <l4/sys/consts.h>
#include <l4/sys/factory.h>
#include <l4/sys/ipc.h>
#include <l4/sys/task.h>
#include <l4/sys/utcb.h>

#include "erx/abi.h"
#include "liberx/backend/fiasco/lock.h"
#include "liberx/backend/fiasco/service.h"
#include "liberx/backend/fiasco/thread.h"
#include "liberx/backend/fiasco/thread_offsets.h"
#include "liberx/backend/fiasco/vm.h"

/*
 * The table's constant address: the area's first pages. Its native UTCB slots sit
 * below the window, where nothing else of the root lives, and 128 slots of 1 KiB
 * is the 2^17 the kernel takes in one area.
 */
#define THREAD_TABLE		ERX_FIASCO_AREA_START
#define THREAD_UTCB_AREA	UINT64_C(0xf00000000)
#define THREAD_UTCB_ORDER	17u
/* A capability slot past the fixed ones: semaphores, then threads. */
#define THREAD_SLOT(n)		(L4_BASE_CAPS_LAST + (((uint64_t)(n) + 1) << L4_CAP_SHIFT))

_Static_assert(sizeof(erx_fiasco_start_t) <= sizeof(((erx_utcb_t *)0)->mr), "the starting registers fit the public UTCB");
_Static_assert(sizeof(erx_fiasco_thread_record_t) <= 2048, "a record is 2 KiB");
_Static_assert(ERX_FIASCO_THREADS_MAX * 2048 == 64 * ERX_PAGE_SIZE, "the table is 64 pages");
_Static_assert(L4_UTCB_OFFSET << 7 == UINT64_C(1) << THREAD_UTCB_ORDER, "128 slots fill the area");
_Static_assert(offsetof(erx_fiasco_thread_record_t, start) + offsetof(erx_regs_t, gpr) ==
    ERX_FIASCO_RECORD_OFF_ARG, "the trampoline's argument");
_Static_assert(offsetof(erx_fiasco_thread_record_t, start) + offsetof(erx_regs_t, sp) ==
    ERX_FIASCO_RECORD_OFF_SP, "the trampoline's stack");
_Static_assert(offsetof(erx_fiasco_thread_record_t, start) + offsetof(erx_regs_t, pc) ==
    ERX_FIASCO_RECORD_OFF_PC, "the trampoline's entry");
_Static_assert(offsetof(erx_fiasco_thread_record_t, start) + offsetof(erx_fiasco_start_t, tls) ==
    ERX_FIASCO_RECORD_OFF_TLS, "the trampoline's thread pointer");
_Static_assert(offsetof(erx_fiasco_start_t, tls) == ERX_SAVED_THREAD_OFF_TLS,
    "the start block is the head of the saved thread's layout");
_Static_assert(L4_UTCB_THREAD_REGS_OFFSET + offsetof(l4_thread_regs_t, free_marker) ==
    ERX_FIASCO_NATIVE_OFF_MARKER, "the native marker");
_Static_assert(L4_UTCB_THREAD_REGS_OFFSET + offsetof(l4_thread_regs_t, user) ==
    ERX_FIASCO_NATIVE_OFF_RECORD, "the native user word");

static uint32_t thread_claim(void);

/* The thread lock: one per task, around the claim. */
static erx_fiasco_lock_t thread_lock;

erx_fiasco_thread_record_t *
erx_fiasco_thread_record(uint32_t index)
{
	return ((erx_fiasco_thread_record_t *)(uintptr_t)(THREAD_TABLE + (uint64_t)index * 2048));
}

erx_fiasco_thread_record_t *
erx_fiasco_thread_self(void)
{
	return ((erx_fiasco_thread_record_t *)l4_utcb_tcr()->user[0]);
}

erx_utcb_t *
erx_utcb_self(void)
{
	return (&erx_fiasco_thread_self()->utcb);
}

uint64_t
erx_fiasco_thread_native_slot(uint32_t index)
{
	return (THREAD_UTCB_AREA + (uint64_t)index * L4_UTCB_OFFSET);
}

uint64_t
erx_fiasco_thread_semaphore_cap(uint32_t index)
{
	return (THREAD_SLOT(index));
}

uint64_t
erx_fiasco_thread_cap(uint32_t index)
{
	return (THREAD_SLOT(ERX_FIASCO_THREADS_MAX + index));
}

const char *
erx_fiasco_thread_table_init(void)
{
	erx_fiasco_thread_record_t *first;
	l4_fpage_t area = l4_fpage(THREAD_UTCB_AREA, THREAD_UTCB_ORDER, L4_FPAGE_RW);
	uint64_t reserved;

	if (erx_fiasco_vm_body(ERX_FIASCO_VM_RESERVE, THREAD_TABLE,
	    ERX_FIASCO_THREADS_MAX * UINT64_C(2048), ERX_VM_FIXED, &reserved) != ERX_OK ||
	    erx_fiasco_vm_body(ERX_FIASCO_VM_COMMIT, THREAD_TABLE,
	    ERX_FIASCO_THREADS_MAX * UINT64_C(2048), 0, NULL) != ERX_OK)
		return ("threads: no memory for the thread table");
	if (l4_error(l4_task_add_ku_mem(L4_BASE_TASK_CAP, &area)) < 0)
		return ("threads: the kernel refused the UTCB area");
	if (l4_error(l4_factory_create(L4_BASE_FACTORY_CAP, L4_PROTO_SEMAPHORE,
	    erx_fiasco_thread_semaphore_cap(0))) < 0)
		return ("threads: the kernel refused the first thread's semaphore");

	first = erx_fiasco_thread_record(0);
	atomic_store_explicit(&first->used, 1, memory_order_relaxed);
	first->index = 0;
	first->semaphore = erx_fiasco_thread_semaphore_cap(0);
	atomic_store_explicit(&first->utcb.self, (uint64_t)(uintptr_t)&first->utcb, memory_order_relaxed);
	l4_utcb_tcr()->user[0] = (l4_umword_t)(uintptr_t)first;
	return (NULL);
}

/*
 * The lowest index whose record is free and whose marker reads 0: the kernel
 * clears a marker some time after a deletion returns, and until then still holds
 * the UTCB. Returns ERX_FIASCO_THREADS_MAX when none is free.
 */
static uint32_t
thread_claim(void)
{
	const l4_thread_regs_t *native;
	uint32_t index;

	erx_fiasco_lock(&thread_lock);
	for (index = 1; index < ERX_FIASCO_THREADS_MAX; index++) {
		native = (const l4_thread_regs_t *)(uintptr_t)(erx_fiasco_thread_native_slot(index) +
		    L4_UTCB_THREAD_REGS_OFFSET);
		if (atomic_load_explicit(&erx_fiasco_thread_record(index)->used, memory_order_relaxed) == 0 &&
		    __atomic_load_n(&native->free_marker, __ATOMIC_ACQUIRE) == 0) {
			atomic_store_explicit(&erx_fiasco_thread_record(index)->used, 1, memory_order_relaxed);
			break;
		}
	}
	erx_fiasco_unlock(&thread_lock);
	return (index);
}

int
erx_thread_create(uint64_t budget, uint64_t space, uint64_t group, uint64_t thread_class,
    uint64_t *thread)
{
	const uint32_t index = thread_claim();
	erx_fiasco_thread_record_t *record;
	erx_fiasco_reply_t reply;
	int status;

	if (index >= ERX_FIASCO_THREADS_MAX)
		return (ERX_ENOMEM);
	record = erx_fiasco_thread_record(index);
	const erx_fiasco_thread_create_request_t request = {
		.caller = erx_fiasco_thread_self()->index, .budget = budget, .space = space,
		.group = group, .thread_class = thread_class, .index = index };

	status = erx_fiasco_service_call(ERX_FIASCO_CALL_THREAD_CREATE, &request, sizeof(request), &reply);
	if (status != ERX_OK) {
		atomic_store_explicit(&record->used, 0, memory_order_relaxed);
		return (status);
	}
	record->index = index;
	record->semaphore = reply.second;
	atomic_store_explicit(&record->utcb.self, (uint64_t)(uintptr_t)&record->utcb, memory_order_relaxed);
	*thread = reply.first;
	return (ERX_OK);
}

/*
 * The marker goes to 1 first, as the kernel may hold the UTCB from the bind on. A
 * failed start leaves it: if the kernel ran its kill path it writes 0 and the
 * index returns, and if it only unbound the thread the index stays lost.
 */
int
erx_thread_start(uint64_t thread)
{
	erx_fiasco_thread_start_request_t request;
	erx_fiasco_thread_record_t *record;
	l4_thread_regs_t *native;
	erx_fiasco_reply_t reply;
	int status;

	if (thread >= ERX_FIASCO_THREADS_MAX)
		return (ERX_EINVAL);
	record = erx_fiasco_thread_record((uint32_t)thread);
	if (atomic_load_explicit(&record->used, memory_order_relaxed) == 0)
		return (ERX_EINVAL);
	native = (l4_thread_regs_t *)(uintptr_t)(erx_fiasco_thread_native_slot((uint32_t)thread) +
	    L4_UTCB_THREAD_REGS_OFFSET);
	__atomic_store_n(&native->free_marker, 1, __ATOMIC_RELEASE);

	request.caller = erx_fiasco_thread_self()->index;
	request.thread = thread;
	status = erx_fiasco_service_call(ERX_FIASCO_CALL_THREAD_START, &request, sizeof(request), &reply);
	/*
	 * ERX_EINVAL deleted nothing, so the record stays; any other refusal deleted the
	 * thread. A refused start leaves the marker it wrote, which is a recorded gap.
	 */
	if (status != ERX_OK && status != ERX_EINVAL)
		atomic_store_explicit(&record->used, 0, memory_order_relaxed);
	return (status);
}
