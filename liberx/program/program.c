/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

/*
 * A program's start-up: the effects around the pure core startup.c (program.h says what
 * each party does). Two threads take part. The first thread, a worker, maps the channel's
 * two sides, starts the event executor and waits on the verdict word. The executor is the
 * inbound lane's one reader: it takes the startup message's record as it is published,
 * into a run of pages sized by the record's header, ringing the session's doorbell
 * whenever its read position crosses what the session waits for, and once the record is
 * whole it plans the start-up. A refused plan stops the program's space with status 127
 * before main and without a line; an accepted one sets the verdict and wakes the first
 * thread, which alone reads the plan from then on. The executor stays the lane's reader:
 * any later frame stops the program the same way.
 *
 * Every failure before main, a mapping or a commit as much as a refused message, stops
 * the program with ERX_PROG_STATUS_REFUSED, as an exec that fails does on UNIX. The layer
 * takes its memory as whole pages (erx_vm_reserve and erx_vm_commit) and calls neither
 * musl's malloc nor its stdio.
 */

#include <pthread.h>
#include <stdatomic.h>
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <string.h>

#include "erx/abi.h"
#include "erx/lane.h"
#include "liberx/backend/api.h"
#include "liberx/program/program.h"
#include "liberx/pthread_executor.h"

int	main(int, char **, char **);

extern char **environ;

/* program_arg's last value, the session's doorbell, is its highest index. */
_Static_assert(ERX_PROGRAM_ARG_DOORBELL < ERX_ARCH_START_ARGS,
    "a program's values fit the argument registers it starts with");

/* The verdict word: the first thread waits while it is VERDICT_WAIT. */
enum { VERDICT_WAIT, VERDICT_GO };

static erx_prog_self_t self;
/* The executor's alone: the inbound lane's reader and the startup message's copy. */
static erx_lane_reader_t inbound;
static uint8_t *message;		/* the record's body, then the check's scratch */
static uint64_t message_run;		/* the run's bytes, whole pages */
static size_t message_len;
static size_t message_have;
/* Written by the executor before VERDICT_GO, read by the first thread after it. */
static erx_prog_startup_t plan;
static _Atomic uint32_t verdict = VERDICT_WAIT;

void
erx_prog_enter(const uint64_t regs[ERX_ARCH_START_ARGS])
{
	memcpy(self.regs, regs, sizeof(self.regs));
}

const erx_prog_self_t *
erx_prog_self(void)
{
	return (&self);
}

/* Stops the program's space with status; the calling thread never runs on. */
static _Noreturn void
stop(int status)
{
	static _Atomic uint32_t never;

	(void)erx_space_stop(ERX_CAP_SELF, status);
	for (;;)
		(void)erx_umtx_wait((uint64_t)(uintptr_t)&never, 0, ERX_WAIT_FOREVER);
}

/* bytes rounded up to whole pages, or 0 when the rounding overflows. */
static uint64_t
page_round(uint64_t bytes)
{
	uint64_t rounded;

	if (__builtin_add_overflow(bytes, ERX_PAGE_SIZE - 1, &rounded))
		return (0);
	return (rounded & ~(uint64_t)(ERX_PAGE_SIZE - 1));
}

/* A run of size bytes of fresh committed pages, size a non-zero multiple of the page, or NULL. */
static void *
pages_take(uint64_t size)
{
	uint64_t addr = 0;

	if (size == 0 || erx_vm_reserve(ERX_CAP_SELF, 0, size, 0, &addr) != ERX_OK)
		return (NULL);
	if (erx_vm_commit(ERX_CAP_SELF, addr, size) != ERX_OK) {
		(void)erx_vm_release(ERX_CAP_SELF, addr, size);
		return (NULL);
	}
	return ((void *)(uintptr_t)addr);
}

/* The first size bytes of the memory object mem, mapped at fresh addresses with prot, or NULL. */
static void *
object_map(uint64_t mem, uint64_t size, uint32_t prot)
{
	uint64_t addr = 0;

	if (size == 0 || erx_vm_reserve(ERX_CAP_SELF, 0, size, 0, &addr) != ERX_OK)
		return (NULL);
	if (erx_vm_map(ERX_CAP_SELF, addr, size, mem, 0, prot) != ERX_OK) {
		(void)erx_vm_release(ERX_CAP_SELF, addr, size);
		return (NULL);
	}
	return ((void *)(uintptr_t)addr);
}

/*
 * Maps the channel's two sides, the program's own read-write and the session's read-only,
 * and readies the inbound lane's reader over them; the lane's size is the ABI's, never a
 * value from a page the session writes.
 */
static bool
channel_open(void)
{
	const uint64_t bytes = erx_lane_side_bytes(ERX_PROGRAM_LANE);
	void *const own = object_map(self.regs[ERX_PROGRAM_ARG_OWN_SIDE], bytes, ERX_PROT_RW);
	const void *const peer = object_map(self.regs[ERX_PROGRAM_ARG_PEER_SIDE], bytes, ERX_PROT_R);

	return (own != NULL && peer != NULL && erx_lane_reader_init(&inbound, peer, own, ERX_PROGRAM_LANE));
}

/*
 * Takes the group's ready labels and counts each: the channel's, the program's peer side's
 * value, which the session bound the program's doorbell with, or another. How many it
 * took; none or an error says there is nothing to look at.
 */
static int
labels_take(void)
{
	const int taken = erx_group_take_ready(ERX_MSG_WORDS);

	for (int at = 0; at < taken; at++) {
		uint64_t label = 0;

		(void)erx_utcb_mr_load(erx_utcb_self(), (size_t)at, &label);
		if (label == self.regs[ERX_PROGRAM_ARG_PEER_SIDE])
			atomic_fetch_add_explicit(&self.rings, 1, memory_order_relaxed);
		else
			atomic_fetch_add_explicit(&self.strays, 1, memory_order_relaxed);
	}
	return (taken);
}

/*
 * A record opened: the startup message's, before any verdict, whose header must be a
 * frame within the profile's bound. Commits one run for its body and, after it, the
 * check's scratch, so a small message costs a few pages and the largest a few hundred.
 */
static void
message_open(const erx_lane_part_t *part)
{
	const size_t scratch = erx_prog_scratch_bytes(part->len);
	const uint64_t body = page_round(part->len), rest = page_round(scratch);

	if (part->kind != ERX_REC_FRAME || part->zero != 0 || part->len > ERX_PROG_FRAME_MAX ||
	    rest == 0 || __builtin_add_overflow(body, rest, &message_run))
		stop(ERX_PROG_STATUS_REFUSED);
	message = pages_take(message_run);
	if (message == NULL)
		stop(ERX_PROG_STATUS_REFUSED);
	message_len = part->len;
	message_have = 0;
}

/* The startup message is whole: plans the start-up, and stops the program or lets it run. */
static void
message_close(void)
{
	const uint64_t body = page_round(message_len);

	if (erx_prog_startup_plan(message, message_len, message + body, message_run - body, &plan) != 0)
		stop(plan.status);
	atomic_store_explicit(&verdict, VERDICT_GO, memory_order_release);
	(void)erx_umtx_wake((uint64_t)(uintptr_t)&verdict, 1);
}

/*
 * Takes the next part of the inbound lane with take, erx_lane_take or erx_lane_take_armed:
 * between records only a header, inside the startup message as much of its body as is
 * published, into the copy after what it holds.
 */
static erx_lane_status_t
lane_take(erx_lane_status_t (*take)(erx_lane_reader_t *, void *, size_t, erx_lane_part_t *),
    erx_lane_part_t *part)
{
	if (inbound.phase != ERX_LANE_IN_BODY)
		return (take(&inbound, NULL, 0, part));
	return (take(&inbound, message + message_have, message_len - message_have, part));
}

/*
 * The event executor: reads the inbound lane until it is empty, then takes the group's
 * labels and parks when there are none. The epochs are read before the lane, so a ring
 * that comes after the empty take moves one and the park returns at once.
 */
static void *
executor_main(void *unused)
{
	const erx_group_stat_t *const group = erx_group_status();
	const uint32_t slot = erx_executor_slot();

	(void)unused;
	for (;;) {
		const uint64_t group_epoch = atomic_load_explicit(&group->epoch, memory_order_acquire);
		const uint64_t own_epoch = atomic_load_explicit(&group->exec[slot].epoch, memory_order_acquire);
		erx_lane_part_t part;
		erx_lane_status_t got = lane_take(erx_lane_take, &part);

		if (got == ERX_LANE_EMPTY)
			got = lane_take(erx_lane_take_armed, &part);
		if (got == ERX_LANE_EMPTY) {
			if (labels_take() <= 0)
				(void)erx_park(group_epoch, own_epoch, ERX_WAIT_FOREVER);
			continue;
		}
		if (got != ERX_LANE_TOOK)
			stop(ERX_PROG_STATUS_REFUSED);
		/* The session may wait for this room; a failed ring is the session's to miss. */
		if (part.ring)
			(void)erx_irq_trigger(self.regs[ERX_PROGRAM_ARG_DOORBELL]);
		if (part.opened) {
			if (atomic_load_explicit(&verdict, memory_order_relaxed) != VERDICT_WAIT)
				stop(erx_prog_later_frame_status());
			message_open(&part);
		}
		message_have += part.copied;
		if (part.closed)
			message_close();
	}
	return (NULL);
}

/*
 * Copies argv's strings, each with its NUL, from *text on, into list[0, count), ends list
 * with NULL and moves *text past them. The plan counted the same strings and their bytes,
 * which sized the storage, so a walk that yields more than count stops the program.
 */
static void
argv_copy(erx_prog_argv_iter_t it, char **list, uint32_t count, char **text)
{
	erx_profile_text_t string;
	uint32_t at = 0;

	while (erx_prog_argv_next(&it, &string)) {
		if (at == count)
			stop(ERX_PROG_STATUS_REFUSED);
		memcpy(*text, string.bytes, string.len);
		(*text)[string.len] = '\0';
		list[at++] = *text;
		*text += string.len + 1;
	}
	list[at] = NULL;
}

/* As argv_copy, for env's strings. */
static void
env_copy(erx_prog_env_iter_t it, char **list, uint32_t count, char **text)
{
	erx_profile_text_t string;
	uint32_t at = 0;

	while (erx_prog_env_next(&it, &string)) {
		if (at == count)
			stop(ERX_PROG_STATUS_REFUSED);
		memcpy(*text, string.bytes, string.len);
		(*text)[string.len] = '\0';
		list[at++] = *text;
		*text += string.len + 1;
	}
	list[at] = NULL;
}

/*
 * The first thread's part once the verdict is VERDICT_GO: maps the data area, copies argv
 * and env into NUL-terminated strings, keeps the rest of the plan in self, gives the
 * message's run back and calls main.
 */
static int
main_run(void)
{
	const uint64_t data_bytes = (uint64_t)plan.data_slots * ERX_PROG_DATA_SLOT_BYTES;
	uint64_t pointers, bytes;
	char **argv, **envp, *text;
	void *data;

	data = object_map(plan.data_area, data_bytes, ERX_PROT_RW);
	if (data == NULL)
		stop(ERX_PROG_STATUS_REFUSED);
	/* argv and env, each with its NULL, then their strings; args_max bounds the strings. */
	if (__builtin_add_overflow((uint64_t)plan.argc, (uint64_t)plan.envc + 2, &pointers) ||
	    __builtin_mul_overflow(pointers, sizeof(char *), &bytes) ||
	    __builtin_add_overflow(bytes, plan.argv_bytes, &bytes) ||
	    __builtin_add_overflow(bytes, plan.env_bytes, &bytes) ||
	    (argv = pages_take(page_round(bytes))) == NULL)
		stop(ERX_PROG_STATUS_REFUSED);
	envp = argv + plan.argc + 1;
	text = (char *)(envp + plan.envc + 1);
	argv_copy(plan.argv, argv, plan.argc, &text);
	env_copy(plan.env, envp, plan.envc, &text);

	self.pid = plan.pid;
	self.ppid = plan.ppid;
	self.pgid = plan.pgid;
	self.spawn = plan.spawn;
	self.umask = plan.umask;
	self.sigmask = plan.sigmask;
	self.sigignore = plan.sigignore;
	self.cwd = plan.cwd;
	self.data_area = data;
	self.data_bytes = data_bytes;
	environ = envp;
	/* Nothing reads the message from here on: the strings are copied and the executor is past it. */
	(void)erx_vm_release(ERX_CAP_SELF, (uint64_t)(uintptr_t)message, message_run);
	return (main((int)plan.argc, argv, envp));
}

int
liberx_program_main(int argc, char **argv, char **envp)
{
	pthread_t executor;

	/* musl's own placeholders; the program's come from its startup message. */
	(void)argc;
	(void)argv;
	(void)envp;
	if (!channel_open() || erx_pthread_create_executor(&executor, NULL, executor_main, NULL) != 0)
		stop(ERX_PROG_STATUS_REFUSED);
	while (atomic_load_explicit(&verdict, memory_order_acquire) == VERDICT_WAIT)
		(void)erx_umtx_wait((uint64_t)(uintptr_t)&verdict, VERDICT_WAIT, ERX_WAIT_FOREVER);
	return (main_run());
}
