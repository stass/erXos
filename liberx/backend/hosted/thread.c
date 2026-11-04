/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

/*
 * The thread calls and the machine's end in a macOS process: a thread is a pthread
 * that moves to the stack its start record names and moves back to end
 * (docs/design-stopgap.md, "The hosted backend"). The pthread's own stack holds
 * nothing but the way back, so a joiner may reuse or release the caller's stack as
 * soon as the thread's clear word reads 0, as natively. The thread pointer is a
 * field here, since the host owns the register.
 */

#include <pthread.h>
#include <stdatomic.h>
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <stdlib.h>
#include <unistd.h>

#include "erx/abi.h"
#include "liberx/backend/api.h"
#include "liberx/backend/hosted/internal.h"

#if defined(__has_feature)
#if __has_feature(address_sanitizer)
#define HOSTED_ASAN 1
#include <sanitizer/common_interface_defs.h>
#endif
#endif

#define THREADS_MAX	128u
/* A handle is never 0, nor an IRQ object's. */
#define HANDLE_BASE	UINT64_C(0x10000)
/* An ordinary exit status apart from 0, for a reset. */
#define EXIT_RESET	75
/* How much of a caller's stack the address sanitizer is told of: it reads only the top. */
#define ASAN_STACK_SPAN	UINT64_C(65536)

typedef enum thread_state {
	THREAD_FREE = 0,
	THREAD_CREATED,
	THREAD_STARTED
} thread_state_t;

typedef struct hosted_thread {
	thread_state_t	state;		/* under thread_lock */
	erx_thread_start_t start;
	uint32_t	slot;
	uint64_t	clear_word;
	uint64_t	release_base;
	uint64_t	release_size;
	uint64_t	host_sp;	/* the way back to the pthread's stack */
} hosted_thread_t;

static pthread_mutex_t thread_lock = PTHREAD_MUTEX_INITIALIZER;
static hosted_thread_t threads[THREADS_MAX];
static _Thread_local hosted_thread_t *thread_self;

_Static_assert(sizeof(erx_thread_start_t) <= sizeof(((erx_utcb_t *)NULL)->mr), "a start record fits the message registers");

/* The thread a handle names, or NULL. Under thread_lock. */
static hosted_thread_t *
thread_find(uint64_t thread)
{
	if (thread < HANDLE_BASE || thread - HANDLE_BASE >= THREADS_MAX)
		return (NULL);
	return (threads[thread - HANDLE_BASE].state != THREAD_FREE ? &threads[thread - HANDLE_BASE] : NULL);
}

static void
sanitizer_before_switch(uint64_t top)
{
#ifdef HOSTED_ASAN
	void *fake_stack;

	__sanitizer_start_switch_fiber(&fake_stack, (const void *)(uintptr_t)(top - ASAN_STACK_SPAN), ASAN_STACK_SPAN);
#else
	(void)top;
#endif
}

static void
sanitizer_after_switch(void)
{
#ifdef HOSTED_ASAN
	__sanitizer_finish_switch_fiber(NULL, NULL, NULL);
#endif
}

/* On the pthread's own stack again: nothing of the caller's stack is used from here on. */
static _Noreturn void
thread_finish(void *arg)
{
	hosted_thread_t *const self = arg;
	const uint32_t slot = self->slot;
	const uint64_t word = self->clear_word;

	sanitizer_after_switch();
	if (self->release_size != 0 && erx_vm_release(self->release_base, self->release_size) != ERX_OK)
		erx_hosted_fatal("erx: hosted: a thread's stack would not release\n");
	if (slot != ERX_NO_EXECUTOR_SLOT)
		erx_hosted_executor_release(slot);
	(void)pthread_mutex_lock(&thread_lock);
	*self = (hosted_thread_t){ .state = THREAD_FREE };
	(void)pthread_mutex_unlock(&thread_lock);
	thread_self = NULL;
	if (word != 0) {
		atomic_store_explicit((_Atomic uint32_t *)(uintptr_t)word, 0, memory_order_release);
		(void)erx_umtx_wake(word, UINT32_MAX);
	}
	pthread_exit(NULL);
}

static _Noreturn void
thread_leave(uint64_t base, uint64_t size)
{
	hosted_thread_t *const self = thread_self;
	uint64_t discarded;

	if (self == NULL)
		pthread_exit(NULL);
	self->release_base = base;
	self->release_size = size;
	sanitizer_before_switch(self->host_sp);
	erx_hosted_switch_stack(self->host_sp, thread_finish, self, &discarded);
}

/* On the caller's stack, where the start record said. An entry that returned has no place to go. */
static _Noreturn void
thread_run(void *arg)
{
	hosted_thread_t *const self = arg;
	void (*const entry)(uint64_t) = (void (*)(uint64_t))(uintptr_t)self->start.regs.pc;

	sanitizer_after_switch();
	entry(self->start.regs.gpr[0]);
	erx_hosted_fatal("erx: hosted: a thread's entry returned\n");
}

static void *
thread_main(void *arg)
{
	hosted_thread_t *const self = arg;

	thread_self = self;
	sanitizer_before_switch(self->start.regs.sp);
	erx_hosted_switch_stack(self->start.regs.sp, thread_run, self, &self->host_sp);
}

int
erx_thread_create(uint64_t budget, uint64_t space, uint64_t group, uint64_t thread_class, uint64_t *thread)
{
	erx_utcb_t *const utcb = erx_utcb_self();
	erx_thread_start_t start;
	uint64_t *const words = (uint64_t *)(void *)&start;
	uint32_t slot = ERX_NO_EXECUTOR_SLOT;
	int status = ERX_ENOMEM;

	(void)budget;
	(void)space;
	(void)group;
	if (thread_class != ERX_THREAD_CLASS_WORKER && thread_class != ERX_THREAD_CLASS_EXECUTOR)
		return (ERX_EINVAL);
	for (size_t word = 0; word < sizeof(start) / sizeof(uint64_t); word++)
		words[word] = atomic_load_explicit(&utcb->mr[word], memory_order_relaxed);
	(void)pthread_mutex_lock(&thread_lock);
	for (uint32_t index = 0; index < THREADS_MAX && status != ERX_OK; index++) {
		if (threads[index].state == THREAD_FREE) {
			threads[index] = (hosted_thread_t){ .state = THREAD_CREATED, .start = start,
			    .slot = ERX_NO_EXECUTOR_SLOT };
			*thread = HANDLE_BASE + index;
			status = ERX_OK;
		}
	}
	(void)pthread_mutex_unlock(&thread_lock);
	if (status != ERX_OK || thread_class != ERX_THREAD_CLASS_EXECUTOR)
		return (status);
	slot = erx_hosted_executor_claim();
	(void)pthread_mutex_lock(&thread_lock);
	if (slot == ERX_NO_EXECUTOR_SLOT)
		*thread_find(*thread) = (hosted_thread_t){ .state = THREAD_FREE };
	else
		thread_find(*thread)->slot = slot;
	(void)pthread_mutex_unlock(&thread_lock);
	return (slot == ERX_NO_EXECUTOR_SLOT ? ERX_ENOMEM : ERX_OK);
}

int
erx_thread_start(uint64_t thread)
{
	hosted_thread_t *self;
	pthread_attr_t attr;
	pthread_t pthread;
	int status = ERX_EINVAL;

	(void)pthread_mutex_lock(&thread_lock);
	self = thread_find(thread);
	if (self != NULL && self->state == THREAD_CREATED) {
		self->state = THREAD_STARTED;
		status = ERX_OK;
		if (pthread_attr_init(&attr) != 0 || pthread_attr_setdetachstate(&attr, PTHREAD_CREATE_DETACHED) != 0 ||
		    pthread_create(&pthread, &attr, thread_main, self) != 0)
			erx_hosted_fatal("erx: hosted: the host refused a thread\n");
		(void)pthread_attr_destroy(&attr);
	}
	(void)pthread_mutex_unlock(&thread_lock);
	return (status);
}

/*
 * A mask is checked as natively and otherwise kept to the host: macOS has no way to
 * hold a thread to a CPU, and a caller can tell only by its timing.
 */
int
erx_thread_set_affinity(uint64_t thread, uint64_t mask)
{
	const long cpus = sysconf(_SC_NPROCESSORS_ONLN);
	const uint64_t all = cpus >= 64 ? UINT64_MAX : (UINT64_C(1) << (cpus > 0 ? cpus : 1)) - 1;
	bool named;

	(void)pthread_mutex_lock(&thread_lock);
	named = thread_find(thread) != NULL;
	(void)pthread_mutex_unlock(&thread_lock);
	return (named && (mask & all) != 0 && (mask & ~all) == 0 ? ERX_OK : ERX_EINVAL);
}

int
erx_thread_set_clear_word(uint64_t thread, uint64_t word)
{
	hosted_thread_t *self;
	int status = ERX_EINVAL;

	(void)pthread_mutex_lock(&thread_lock);
	self = thread_find(thread);
	if (self != NULL) {
		self->clear_word = word;
		status = ERX_OK;
	}
	(void)pthread_mutex_unlock(&thread_lock);
	return (status);
}

void
erx_thread_exit(void)
{
	thread_leave(0, 0);
}

void
erx_thread_exit_release(uint64_t base, uint64_t size)
{
	thread_leave(base, size);
}

uint64_t
erx_thread_pointer(void)
{
	return (thread_self != NULL ? thread_self->start.tls : 0);
}

uint32_t
erx_executor_slot(void)
{
	return (thread_self != NULL ? thread_self->slot : ERX_NO_EXECUTOR_SLOT);
}

/* The sanitizers' own exit paths run, so what they found decides the status. */
int
erx_machine_end(uint64_t res, uint32_t how)
{
	(void)res;
	if (how != ERX_END_OFF && how != ERX_END_RESET)
		return (ERX_EINVAL);
	exit(how == ERX_END_OFF ? EXIT_SUCCESS : EXIT_RESET);
}
