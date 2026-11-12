/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

/*
 * The caller's side of a thread's life: the record table and the claim, which run
 * in the calling thread under the thread lock, the requests to the service, which
 * alone calls the kernel about a thread, and the reaper
 * (docs/design-stopgap.md, "Thread exit"), which ends what exits.
 */

#include <stdatomic.h>
#include <stddef.h>
#include <stdint.h>

#include <l4/sys/consts.h>
#include <l4/sys/factory.h>
#include <l4/sys/ipc.h>
#include <l4/sys/semaphore.h>
#include <l4/sys/task.h>
#include <l4/sys/thread.h>
#include <l4/sys/utcb.h>

#include "erx/abi.h"
#include "liberx/backend/fiasco/console.h"
#include "liberx/backend/fiasco/lock.h"
#include "liberx/backend/fiasco/log.h"
#include "liberx/backend/fiasco/park.h"
#include "liberx/backend/fiasco/service.h"
#include "liberx/backend/fiasco/thread.h"
#include "liberx/backend/fiasco/thread_claim.h"
#include "liberx/backend/fiasco/thread_offsets.h"
#include "liberx/backend/fiasco/time_table.h"
#include "liberx/backend/fiasco/umtx.h"
#include "liberx/backend/fiasco/vm.h"

/*
 * The table's constant address: the area's first pages. Its native UTCB slots sit
 * below the window, where nothing else of the root lives, and 128 slots of 1 KiB
 * is the 2^17 the kernel takes in one area.
 */
#define THREAD_TABLE		ERX_FIASCO_AREA_START
#define THREAD_UTCB_AREA	UINT64_C(0xf00000000)
/* A capability slot past the fixed ones: semaphores, then threads. */
#define THREAD_SLOT(n)		(L4_BASE_CAPS_LAST + (((uint64_t)(n) + 1) << L4_CAP_SHIFT))
#define REAPER_STACK_BYTES	16384u

_Static_assert(sizeof(erx_fiasco_start_t) <= sizeof(((erx_utcb_t *)0)->mr), "the starting registers fit the public UTCB");
_Static_assert(sizeof(erx_fiasco_thread_record_t) <= ERX_FIASCO_THREAD_RECORD_BYTES, "a record fits its slot");
_Static_assert(ERX_FIASCO_THREAD_TABLE_BYTES == 64 * ERX_PAGE_SIZE, "the table is 64 pages");
_Static_assert(ERX_BACKEND_PARK_OBJECTS_MAX * sizeof(uint64_t) <= ERX_PAGE_SIZE, "the labels fill one page at most");
_Static_assert(L4_UTCB_OFFSET << 7 == UINT64_C(1) << ERX_FIASCO_UTCB_AREA_ORDER, "128 slots fill the area");
_Static_assert(offsetof(erx_fiasco_thread_record_t, start) + offsetof(erx_regs_t, gpr) ==
    ERX_FIASCO_RECORD_OFF_ARGS, "the trampoline's arguments");
_Static_assert(ERX_FIASCO_START_ARGS * sizeof(uint64_t) <= sizeof(((erx_regs_t *)0)->gpr),
    "the trampoline's arguments are general registers");
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
static bool	thread_claim_used(void *, uint32_t);
static uint64_t thread_claim_marker(void *, uint32_t);
static void	reaper_main(uint64_t);
static void	reaper_reap(erx_fiasco_thread_record_t *);
static _Noreturn void reaper_refused(const char *);
static _Noreturn void thread_exit_to_reaper(erx_fiasco_thread_record_t *);

/* The thread lock: one per task, around the claim and the reaper's list. */
static erx_fiasco_lock_t thread_lock;
/* The records exited and not reaped yet, oldest first. */
static erx_fiasco_thread_record_t *reap_head, *reap_tail;
/* The reaper's record: exits up its semaphore. Written once, before any thread exits. */
static erx_fiasco_thread_record_t *reaper_record;
static _Alignas(16) uint8_t reaper_stack[REAPER_STACK_BYTES];
static void *thread_first_utcb;

void *
erx_fiasco_thread_first_utcb(void)
{
	return (thread_first_utcb);
}

erx_fiasco_thread_record_t *
erx_fiasco_thread_record(uint32_t index)
{
	return ((erx_fiasco_thread_record_t *)(uintptr_t)(THREAD_TABLE + (uint64_t)index * ERX_FIASCO_THREAD_RECORD_BYTES));
}

_Atomic uint64_t *
erx_fiasco_labels(void)
{
	return ((_Atomic uint64_t *)(uintptr_t)(THREAD_TABLE + ERX_FIASCO_THREAD_TABLE_BYTES));
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

uint64_t
erx_fiasco_root_slot_cap(uint32_t slot)
{
	return (erx_fiasco_thread_cap(slot));
}

void
erx_fiasco_thread_first_init(void)
{
	erx_fiasco_thread_record_t *first;

	first = erx_fiasco_thread_record(0);
	atomic_store_explicit(&first->used, ERX_FIASCO_THREAD_STARTED, memory_order_relaxed);
	first->index = 0;
	first->semaphore = erx_fiasco_thread_semaphore_cap(0);
	first->executor_slot = ERX_BACKEND_PARK_NO_SLOT;
	thread_first_utcb = l4_utcb();
	atomic_store_explicit(&first->utcb.self, (uint64_t)(uintptr_t)&first->utcb, memory_order_relaxed);
	l4_utcb_tcr()->user[0] = (l4_umword_t)(uintptr_t)first;
}

static bool
thread_claim_used(void *context, uint32_t index)
{
	(void)context;
	return (atomic_load_explicit(&erx_fiasco_thread_record(index)->used, memory_order_acquire) != ERX_FIASCO_THREAD_FREE);
}

static uint64_t
thread_claim_marker(void *context, uint32_t index)
{
	const l4_thread_regs_t *const native = (const l4_thread_regs_t *)(uintptr_t)
	    (erx_fiasco_thread_native_slot(index) + L4_UTCB_THREAD_REGS_OFFSET);

	(void)context;
	return (__atomic_load_n(&native->free_marker, __ATOMIC_ACQUIRE));
}

/* Returns ERX_FIASCO_THREADS_MAX when no index is claimable. */
static uint32_t
thread_claim(void)
{
	static const erx_fiasco_claim_view_t view = { .used = thread_claim_used, .marker = thread_claim_marker };
	uint32_t index;

	erx_fiasco_lock(&thread_lock);
	index = erx_fiasco_thread_claim_pick(&view, NULL, 1, ERX_FIASCO_THREADS_MAX);
	if (index < ERX_FIASCO_THREADS_MAX)
		atomic_store_explicit(&erx_fiasco_thread_record(index)->used, ERX_FIASCO_THREAD_CLAIMED, memory_order_relaxed);
	erx_fiasco_unlock(&thread_lock);
	return (index);
}

int
erx_thread_create(uint64_t budget, uint64_t space, uint64_t group, uint64_t thread_class,
    uint64_t *thread)
{
	uint32_t index, slot = ERX_BACKEND_PARK_NO_SLOT;
	erx_fiasco_thread_record_t *record;
	erx_fiasco_reply_t reply;
	int status;

	if (thread_class != ERX_THREAD_CLASS_WORKER && thread_class != ERX_THREAD_CLASS_EXECUTOR)
		return (ERX_EINVAL);
	/* Another space takes only its first thread, at index 0 of the table its task was made with. */
	if (space != 0) {
		const erx_fiasco_thread_create_request_t first = { .caller = erx_fiasco_thread_self()->index,
		    .budget = budget, .space = space, .group = group, .thread_class = thread_class };

		status = erx_fiasco_service_call(ERX_FIASCO_CALL_THREAD_CREATE, &first, sizeof(first), &reply);
		if (status == ERX_OK)
			*thread = reply.first;
		return (status);
	}
	index = thread_claim();
	if (index >= ERX_FIASCO_THREADS_MAX)
		return (ERX_ENOMEM);
	record = erx_fiasco_thread_record(index);
	if (thread_class == ERX_THREAD_CLASS_EXECUTOR) {
		slot = erx_fiasco_executor_claim(index);
		if (slot == ERX_BACKEND_PARK_NO_SLOT) {
			atomic_store_explicit(&record->used, ERX_FIASCO_THREAD_FREE, memory_order_release);
			return (ERX_ENOMEM);
		}
	}
	const erx_fiasco_thread_create_request_t request = {
		.caller = erx_fiasco_thread_self()->index, .budget = budget, .space = space,
		.group = group, .thread_class = thread_class, .index = index };

	status = erx_fiasco_service_call(ERX_FIASCO_CALL_THREAD_CREATE, &request, sizeof(request), &reply);
	if (status != ERX_OK) {
		if (slot != ERX_BACKEND_PARK_NO_SLOT)
			erx_fiasco_executor_release(slot);
		atomic_store_explicit(&record->used, ERX_FIASCO_THREAD_FREE, memory_order_release);
		return (status);
	}
	record->index = index;
	record->semaphore = reply.second;
	record->executor_slot = slot;
	record->clear_word = 0;
	record->release_base = 0;
	record->release_size = 0;
	record->reap_next = NULL;
	atomic_store_explicit(&record->utcb.self, (uint64_t)(uintptr_t)&record->utcb, memory_order_relaxed);
	atomic_store_explicit(&record->used, ERX_FIASCO_THREAD_CREATED, memory_order_release);
	*thread = reply.first;
	return (ERX_OK);
}

/*
 * The marker goes to 1 first, as the kernel may hold the UTCB from the bind on, and
 * only for a thread created and not started: see erx_fiasco_thread_state_t. A failed
 * start leaves it: if the kernel ran its kill path it writes 0 and the index returns,
 * and if it only unbound the thread the index stays lost.
 */
int
erx_thread_start(uint64_t thread)
{
	erx_fiasco_thread_start_request_t request;
	erx_fiasco_thread_record_t *record;
	l4_thread_regs_t *native;
	erx_fiasco_reply_t reply;
	uint32_t state = ERX_FIASCO_THREAD_CREATED;
	int status;

	request.caller = erx_fiasco_thread_self()->index;
	request.thread = thread;
	request.trampoline = (uint64_t)(uintptr_t)erx_fiasco_thread_trampoline;
	/* Another task's first thread has no record here and no trampoline of ours. */
	if (thread >= ERX_FIASCO_THREADS_MAX)
		return (erx_fiasco_service_call(ERX_FIASCO_CALL_THREAD_START, &request, sizeof(request), &reply));
	record = erx_fiasco_thread_record((uint32_t)thread);
	if (!atomic_compare_exchange_strong_explicit(&record->used, &state, ERX_FIASCO_THREAD_STARTED,
	    memory_order_acquire, memory_order_relaxed))
		return (ERX_EINVAL);
	native = (l4_thread_regs_t *)(uintptr_t)(erx_fiasco_thread_native_slot((uint32_t)thread) +
	    L4_UTCB_THREAD_REGS_OFFSET);
	__atomic_store_n(&native->free_marker, 1, __ATOMIC_RELEASE);

	status = erx_fiasco_service_call(ERX_FIASCO_CALL_THREAD_START, &request, sizeof(request), &reply);
	/* A created record has its kernel objects, so a refusal here deleted them. It leaves the marker it wrote, a recorded gap. */
	if (status != ERX_OK) {
		if (record->executor_slot != ERX_BACKEND_PARK_NO_SLOT)
			erx_fiasco_executor_release(record->executor_slot);
		atomic_store_explicit(&record->used, ERX_FIASCO_THREAD_FREE, memory_order_release);
	}
	return (status);
}

int
erx_thread_set_affinity(uint64_t thread, uint64_t mask)
{
	const erx_fiasco_thread_set_affinity_request_t request = { .caller = erx_fiasco_thread_self()->index,
	    .thread = thread, .mask = mask };
	erx_fiasco_reply_t reply;

	return (erx_fiasco_service_call(ERX_FIASCO_CALL_THREAD_SET_AFFINITY, &request, sizeof(request), &reply));
}

int
erx_fiasco_thread_set_clear_word(uint64_t thread, uint64_t word)
{
	if (thread >= ERX_FIASCO_THREADS_MAX ||
	    atomic_load_explicit(&erx_fiasco_thread_record((uint32_t)thread)->used, memory_order_acquire) == ERX_FIASCO_THREAD_FREE)
		return (ERX_EINVAL);
	erx_fiasco_thread_record((uint32_t)thread)->clear_word = word;
	return (ERX_OK);
}

void
erx_yield(void)
{
	(void)l4_thread_yield();
}

bool
erx_fiasco_semaphore_down(uint64_t semaphore, uint64_t deadline)
{
	l4_timeout_t timeout = L4_IPC_NEVER;
	uint64_t wait_us;

	for (;;) {
		if (deadline != ERX_FIASCO_UMTX_FOREVER) {
			wait_us = erx_fiasco_time_wait_us(erx_fiasco_clock_ns(), deadline, L4_TIMEOUT_US_MAX);
			if (wait_us == 0)
				return (false);
			timeout = l4_timeout(L4_IPC_TIMEOUT_NEVER, l4_timeout_from_us(wait_us));
		}
		if (l4_ipc_error(l4_semaphore_down((l4_cap_idx_t)semaphore, timeout), l4_utcb()) == 0)
			return (true);
	}
}

#ifdef ERX_FIASCO_TEST_HOOKS
void
erx_fiasco_test_semaphore_up(uint64_t semaphore)
{
	(void)l4_semaphore_up((l4_cap_idx_t)semaphore);
}

void
erx_fiasco_test_ipc_sleep_us(uint64_t microseconds)
{
	(void)l4_ipc_sleep(l4_timeout(L4_IPC_TIMEOUT_NEVER, l4_timeout_from_us(
	    microseconds < L4_TIMEOUT_US_MAX ? microseconds : L4_TIMEOUT_US_MAX)));
}
#endif

/* On the list under the lock, then an up: the reaper finds the record or was already due to look. */
static _Noreturn void
thread_exit_to_reaper(erx_fiasco_thread_record_t *record)
{
	record->reap_next = NULL;
	erx_fiasco_lock(&thread_lock);
	if (reap_tail != NULL)
		reap_tail->reap_next = record;
	else
		reap_head = record;
	reap_tail = record;
	erx_fiasco_unlock(&thread_lock);
	(void)l4_semaphore_up((l4_cap_idx_t)reaper_record->semaphore);
	erx_fiasco_sleep_forever();
}

void
erx_thread_exit(void)
{
	thread_exit_to_reaper(erx_fiasco_thread_self());
}

void
erx_thread_exit_release(uint64_t base, uint64_t size)
{
	erx_fiasco_thread_record_t *const record = erx_fiasco_thread_self();

	record->release_base = base;
	record->release_size = size;
	thread_exit_to_reaper(record);
}

static _Noreturn void
reaper_refused(const char *line)
{
	size_t length = 0;

	while (line[length] != '\0')
		length++;
	erx_fiasco_console_write(line, length);
	erx_fiasco_machine_off();
}

/*
 * The order is the contract (docs/design-stopgap.md, "Thread exit"): once the
 * deletion returns the thread never runs again, so its stack and range are free;
 * a joiner returns only after the clear, and frees the stack then; and the index
 * goes back last, so no new thread shares its identifier with the word just cleared.
 */
static void
reaper_reap(erx_fiasco_thread_record_t *record)
{
	const erx_fiasco_thread_reap_request_t request = { .caller = erx_fiasco_thread_self()->index,
	    .thread = record->index };
	erx_fiasco_reply_t reply;

	if (erx_fiasco_service_call(ERX_FIASCO_CALL_THREAD_REAP, &request, sizeof(request), &reply) != ERX_OK)
		reaper_refused("erx: reaper: the service refused a deletion\n");
	if (record->release_size != 0 && erx_vm_release(ERX_CAP_SELF, record->release_base, record->release_size) != ERX_OK)
		reaper_refused("erx: reaper: the service refused a detached thread's range\n");
	if (record->clear_word != 0) {
		atomic_store_explicit((_Atomic uint32_t *)(uintptr_t)record->clear_word, 0, memory_order_release);
		(void)erx_umtx_wake(record->clear_word, 1);
	}
	if (record->executor_slot != ERX_BACKEND_PARK_NO_SLOT)
		erx_fiasco_executor_release(record->executor_slot);
	atomic_store_explicit(&record->used, ERX_FIASCO_THREAD_FREE, memory_order_release);
}

static void
reaper_main(uint64_t argument)
{
	erx_fiasco_thread_record_t *const self = erx_fiasco_thread_self();
	erx_fiasco_thread_record_t *record;

	(void)argument;
	for (;;) {
		(void)erx_fiasco_semaphore_down(self->semaphore, ERX_FIASCO_UMTX_FOREVER);
		for (;;) {
			erx_fiasco_lock(&thread_lock);
			record = reap_head;
			if (record != NULL) {
				reap_head = record->reap_next;
				if (reap_head == NULL)
					reap_tail = NULL;
			}
			erx_fiasco_unlock(&thread_lock);
			if (record == NULL)
				break;
			reaper_reap(record);
		}
	}
}

const char *
erx_fiasco_reaper_start(void)
{
	erx_fiasco_start_t start = { 0 };
	const uint64_t *const words = (const uint64_t *)(const void *)&start;
	erx_utcb_t *const utcb = erx_utcb_self();
	uint64_t thread;

	start.regs.sp = (uint64_t)(uintptr_t)(reaper_stack + sizeof(reaper_stack));
	start.regs.pc = (uint64_t)(uintptr_t)reaper_main;
	for (size_t word = 0; word < sizeof(start) / sizeof(uint64_t); word++)
		atomic_store_explicit(&utcb->mr[word], words[word], memory_order_relaxed);
	if (erx_thread_create(0, 0, 0, ERX_THREAD_CLASS_WORKER, &thread) != ERX_OK)
		return ("threads: no thread for the reaper");
	reaper_record = erx_fiasco_thread_record((uint32_t)thread);
	if (erx_thread_start(thread) != ERX_OK)
		return ("threads: the reaper would not start");
	return (NULL);
}
