/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 *
 * The erx_program port driver's effects (docs/design-runtime.md, "Programs as ports"): a
 * port runs one program of the session's release. Every decision is erx_program_core.c's;
 * this file applies each action the core returns with the kernel call it names and feeds
 * the outcome back, so the order of the start, its undo and the end are the core's alone.
 *
 * The driver's start callback runs the whole start: the core's steps, or their undos once one
 * fails. A port whose start failed stays open with nothing made, so that erx_program:start/1
 * reads the failure with port_control and closes it. The start stops before the first
 * thread runs: erx_program:start/1 reads the data area's value from the start's answer,
 * hands the startup message it builds with it to CONTROL_SEND, which writes it into the
 * channel's inbound lane as room returns, and then starts the thread with CONTROL_RUN;
 * the end admits each (docs/design-runtime.md, "Programs as ports"). The end runs in the input task: the
 * gate worker keeps each exit and fault record of the program's spaces in the port's slot
 * and triggers the port's IRQ object, whose delivery schedules this port's input task,
 * which takes the records and feeds them to the core. Each of the program's two spaces
 * carries a label of its own, so the label a record was kept for says which space it is
 * from. Reading the start's answer and closing the port feed the core too. All of these run
 * under the port's lock, so a port's start, input tasks, control calls and stop follow one
 * another, and the input task first runs after the start returned.
 *
 * The start also makes the program's channel and data area from the session's own budget,
 * maps the channel into the session, and installs the program's copies into its image's
 * table (docs/design-programs.md, "The channel"); the session keeps every DESTROY.
 *
 * This file is ERTS's one caller of erx_space_create, erx_image_map, erx_thread_create and
 * erx_cap_pass, and of erx_space_stop on another space
 * (tools/lib/erx/chokepoint_rules/program.rb).
 */

#ifdef HAVE_CONFIG_H
#include "config.h"
#endif

#include <stdatomic.h>
#include <stdbool.h>
#include <string.h>

#include "sys.h"
#include "erl_vm.h"
#include "global.h"
#include "erl_driver.h"
#include "liberx/backend/api.h"
#include "erx/lane.h"
#include "erx/release.h"
#include "erx_event.h"
#include "erx_gate.h"
#include "erx_program_core.h"

/*
 * The owner's port_control commands. Each answers "ok" or the refusing status's
 * e-prefixed name: STARTED how the start ended, "ok" followed by the data area's value in
 * the program's table, 8 bytes big-endian; SEND the frame it carries, which the driver
 * writes into the inbound lane as room returns; RUN, with no payload, the first thread's
 * start.
 */
#define CONTROL_STARTED		1
#define CONTROL_SEND		2
#define CONTROL_RUN		3
/*
 * The capabilities each of a program's spaces may hold: the image's install takes
 * ERX_PROGRAM_INSTALLS of them, and the rest is the program's own.
 */
#define PROGRAM_CAP_LIMIT	16u
_Static_assert(ERX_PROGRAM_INSTALLS <= PROGRAM_CAP_LIMIT, "the install fits the image's table");
/*
 * The session's pool for programs, which a spec's cap must not exceed. The stopgap keeps
 * budgets as records and reports no budget's cap, so the session has no pool to read yet;
 * until it does, the carve of the program's budget is the only bound (TODO.md).
 */
#define PROGRAM_POOL		UINT64_MAX

/*
 * The labels programs' spaces carry, two per program and never reused, so that no record
 * of an ended program's space reaches a later port (erx_gate.h). 0 is never one; at two
 * labels a start, the count cannot wrap within any machine's life.
 */
static _Atomic uint64_t labels_given;

/*
 * The channel's two sides, each one memory object in a lane side's layout
 * (erx_lane_side_bytes), named by their writer: the session's side holds the inbound ring
 * and the outbound reader page, the program's side the outbound ring and the inbound reader
 * page. channel_sides gives each the program_arg index its value takes in the program,
 * named from the program's view, and the session maps each as the core says
 * (erx_program_session_prot), so the core's rights decide both parties' access.
 */
enum { SESSION_SIDE, PROGRAM_SIDE, CHANNEL_SIDES };
static const uint32_t channel_sides[CHANNEL_SIDES] = {
	[SESSION_SIDE] = ERX_PROGRAM_ARG_PEER_SIDE,
	[PROGRAM_SIDE] = ERX_PROGRAM_ARG_OWN_SIDE,
};

typedef struct {
	ErlDrvPort		port;
	erx_program_spec_t	spec;
	uint8_t			image_path[ERX_PACK_PATH_MAX];
	int			start_error;	/* the start's run's answer */
	erx_program_end_t	end;		/* meaningful once the start answered ERX_OK */
	uint64_t		anchor_label;	/* what the anchor's records are kept under */
	uint64_t		image_label;	/* and the image's */
	/* What the start made, each ERX_CAP_NULL, or address 0, until its step made it. */
	uint64_t		side[CHANNEL_SIDES];	/* the channel's sides, by SESSION_SIDE and PROGRAM_SIDE */
	uint64_t		side_addr[CHANNEL_SIDES]; /* and the session's mappings of them */
	uint64_t		bell;		/* the program's doorbell */
	uint64_t		data;		/* the program's data area */
	uint64_t		budget;
	uint64_t		group;
	uint64_t		irq;		/* the session's doorbell, the port's own IRQ object */
	uint32_t		sink;		/* the event table's label for the port */
	uint64_t		anchor;
	uint64_t		image;
	uint64_t		thread;
	uint64_t		pc;		/* the image's entry, from erx_image_map */
	/* What the install made of each copy: its value in the image's table, by install index. */
	uint64_t		installed[ERX_PROGRAM_INSTALLS];
	/*
	 * The inbound lane's writer, ready once the channel is mapped, and the one frame it
	 * writes, NULL but between a WRITE and the frame's WRITTEN or BROKEN; offered is
	 * CONTROL_SEND's copy while the end decides on it.
	 */
	erx_lane_writer_t	writer;
	uint8_t			*frame;
	size_t			frame_len;
	uint8_t			*offered;
	size_t			 offered_len;
} program_t;

extern ErlDrvEntry erx_program_driver_entry;

/* One decimal word and the space after it, into *value: false on anything else or above UINT64_MAX. */
static bool
open_word(const char **at, uint64_t *value)
{
	const char *p = *at;
	uint64_t v = 0;

	if (*p < '0' || *p > '9')
		return (false);
	for (; *p >= '0' && *p <= '9'; p++) {
		if (v > (UINT64_MAX - (uint64_t)(*p - '0')) / 10)
			return (false);
		v = v * 10 + (uint64_t)(*p - '0');
	}
	if (*p != ' ')
		return (false);
	*at = p + 1;
	*value = v;
	return (true);
}

/*
 * "erx_program Pid Guarantee Cap Slots Image", as erx_program:start/1 writes it: four decimal
 * words, then the image's path, the rest of the command. Only the form is checked here;
 * the core checks the spec's values whole.
 */
static bool
program_open_parse(const char *command, program_t *program)
{
	static const char name[] = "erx_program ";
	const char *at = command;
	uint64_t pid;
	size_t len;

	if (strncmp(at, name, sizeof(name) - 1) != 0)
		return (false);
	at += sizeof(name) - 1;
	if (!open_word(&at, &pid) || !open_word(&at, &program->spec.guarantee) ||
	    !open_word(&at, &program->spec.cap) || !open_word(&at, &program->spec.slots) ||
	    pid > (uint64_t)INT64_MAX)
		return (false);
	len = strlen(at);
	if (len > sizeof(program->image_path))
		return (false);
	memcpy(program->image_path, at, len);
	program->spec.image = program->image_path;
	program->spec.image_len = len;
	program->spec.pid = (int64_t)pid;
	return (true);
}

/*
 * The index of the session release's file named by the spec's image, the entry
 * erx_image_map takes from the release's slice: ERX_OK, or ERX_EINVAL when no file of the
 * release has that name, or erx_release_entry's refusal. erx_release_entry numbers the
 * files as the slice does.
 */
static int
release_index(const program_t *program, uint64_t *index)
{
	erx_release_entry_t *const entry = driver_alloc(sizeof(*entry));
	int status;

	if (entry == NULL)
		return (ERX_ENOMEM);
	for (uint64_t at = 0; (status = erx_release_entry(at, entry)) == ERX_OK; at++) {
		if (entry->path_length == program->spec.image_len &&
		    memcmp(entry->path, program->spec.image, program->spec.image_len) == 0) {
			*index = at;
			break;
		}
	}
	driver_free(entry);
	/* Past the release's last file, no file has that name. */
	return (status == ERX_ERANGE ? ERX_EINVAL : status);
}

/*
 * The first thread's starting registers, as erx_thread_create reads them: the image's entry,
 * and in each program_arg argument register the value the install made of that index's
 * copy (abi/erx_abi.txt), every other register 0.
 */
static void
first_registers(const program_t *program)
{
	erx_thread_start_t start;
	uint64_t words[sizeof(start) / sizeof(uint64_t)];

	memset(&start, 0, sizeof(start));
	start.regs.pc = program->pc;
	for (uint32_t arg = 0; arg < ERX_PROGRAM_INSTALL_DATA; arg++)
		start.regs.gpr[arg] = program->installed[arg];
	memcpy(words, &start, sizeof(words));
	for (size_t word = 0; word < sizeof(words) / sizeof(words[0]); word++)
		(void)erx_utcb_mr_store(erx_utcb_self(), word, words[word]);
}

/* Destroys an object the start made, if it did, and closes the session's capability to it. */
static int
destroy(uint64_t *object)
{
	int status;

	if (*object == ERX_CAP_NULL)
		return (ERX_OK);
	status = erx_object_destroy(*object);
	(void)erx_cap_close(*object);
	*object = ERX_CAP_NULL;
	return (status);
}

/* Destroys the channel's memory objects the start made. */
static void
channel_destroy(program_t *program)
{
	for (uint32_t side = 0; side < CHANNEL_SIDES; side++)
		(void)destroy(&program->side[side]);
}

/* Releases the session's mappings of the channel the start made. */
static void
channel_unmap(program_t *program)
{
	const uint64_t bytes = erx_lane_side_bytes(ERX_PROGRAM_LANE);

	for (uint32_t side = 0; side < CHANNEL_SIDES; side++) {
		if (program->side_addr[side] != 0)
			(void)erx_vm_release(ERX_CAP_SELF, program->side_addr[side], bytes);
		program->side_addr[side] = 0;
	}
}

/*
 * The channel's two sides, from the session's budget, each one lane side's bytes. A step
 * makes all or nothing, so a failure destroys those already made.
 */
static int
channel_create(program_t *program, uint64_t budget)
{
	for (uint32_t side = 0; side < CHANNEL_SIDES; side++) {
		const int status = erx_mem_create(budget, erx_lane_side_bytes(ERX_PROGRAM_LANE), 0,
		    &program->side[side]);

		if (status != ERX_OK) {
			channel_destroy(program);
			return (status);
		}
	}
	return (ERX_OK);
}

/*
 * The session's mappings of the channel, as erx_program_session_prot says, all or none,
 * and the inbound lane's writer over them: the session's side is its ring, the program's
 * side holds the reader page, and the size is the ABI's.
 */
static int
channel_map(program_t *program)
{
	const uint64_t bytes = erx_lane_side_bytes(ERX_PROGRAM_LANE);

	for (uint32_t side = 0; side < CHANNEL_SIDES; side++) {
		uint64_t addr = 0;
		int status = erx_vm_reserve(ERX_CAP_SELF, 0, bytes, 0, &addr);

		if (status == ERX_OK) {
			status = erx_vm_map(ERX_CAP_SELF, addr, bytes, program->side[side], 0,
			    erx_program_session_prot(channel_sides[side]));
			if (status != ERX_OK)
				(void)erx_vm_release(ERX_CAP_SELF, addr, bytes);
		}
		if (status != ERX_OK) {
			channel_unmap(program);
			return (status);
		}
		program->side_addr[side] = addr;
	}
	if (!erx_lane_writer_init(&program->writer, (void *)(uintptr_t)program->side_addr[SESSION_SIDE],
	    (const void *)(uintptr_t)program->side_addr[PROGRAM_SIDE], ERX_PROGRAM_LANE)) {
		channel_unmap(program);
		return (ERX_EINVAL);
	}
	return (ERX_OK);
}

/* Drops the frame being written, if any. */
static void
frame_drop(program_t *program)
{
	if (program->frame != NULL)
		driver_free(program->frame);
	program->frame = NULL;
	program->frame_len = 0;
}

/*
 * Passes the program's copies into the image's table, each with the rights the core gives
 * its index, in the passes the core sizes, and keeps the value each copy took there. A
 * pass refused partway leaves copies in the image's table, which go with the image.
 */
static int
install(program_t *program)
{
	erx_utcb_t *const utcb = erx_utcb_self();
	uint64_t handles[ERX_PROGRAM_INSTALLS] = {
		[ERX_PROGRAM_ARG_BUDGET] = program->budget,
		[ERX_PROGRAM_ARG_GROUP] = program->group,
		[ERX_PROGRAM_ARG_DOORBELL] = program->irq,
		[ERX_PROGRAM_INSTALL_DATA] = program->data,
	};
	uint32_t count;

	for (uint32_t side = 0; side < CHANNEL_SIDES; side++)
		handles[channel_sides[side]] = program->side[side];
	for (uint32_t first = 0; (count = erx_program_install_batch(first)) > 0; first += count) {
		int status;

		for (uint32_t item = 0; item < count; item++) {
			uint64_t desc = 0;

			(void)erx_msg_item_desc_rights_set(&desc, erx_program_install_rights(first + item));
			(void)erx_msg_item_desc_move_set(&desc, false);
			(void)erx_utcb_mr_store(utcb, 2 * item, desc);
			(void)erx_utcb_mr_store(utcb, 2 * item + 1, handles[first + item]);
		}
		status = erx_cap_pass(ERX_CAP_SELF, program->image, count);
		if (status != ERX_OK)
			return (status);
		for (uint32_t item = 0; item < count; item++)
			(void)erx_utcb_mr_load(utcb, 2 * item + 1, &program->installed[first + item]);
	}
	return (ERX_OK);
}

static int
close_cap(uint64_t *cap)
{
	const int status = erx_cap_close(*cap);

	*cap = ERX_CAP_NULL;
	return (status);
}

/* {Port, {exit_status, Status}} to the port's owner. */
static void
report(program_t *program, int64_t status)
{
	ErlDrvSInt64 value = status;
	ErlDrvTermData message[] = {
		ERL_DRV_PORT, driver_mk_port(program->port),
		ERL_DRV_ATOM, driver_mk_atom("exit_status"),
		ERL_DRV_INT64, (ErlDrvTermData)&value,
		ERL_DRV_TUPLE, 2,
		ERL_DRV_TUPLE, 2,
	};

	(void)erl_drv_output_term(driver_mk_port(program->port), message,
	    (int)(sizeof(message) / sizeof(message[0])));
}

/*
 * Applies one of the core's actions, other than ERX_PROGRAM_DONE and ERX_PROGRAM_CLOSE_PORT,
 * which the callers act on themselves: the kernel's answer for a start step, which the
 * core reads, the answer to the owner's command for THREAD_START and WRITE, and any status
 * for the rest, which nothing reads. The session's budget and
 * group are the boot information's; the program's spaces name the domain's fault gate and
 * carry their own labels (erx_gate.h).
 */
static int
apply(program_t *program, erx_program_action_t action)
{
	const erx_boot_info_t *const boot = erx_runtime_boot();
	uint64_t index;
	int status;

	switch (action.act) {
	case ERX_PROGRAM_CHANNEL_CREATE:
		return (channel_create(program, boot->budget.raw));
	case ERX_PROGRAM_CHANNEL_MAP:
		return (channel_map(program));
	case ERX_PROGRAM_BELL_CREATE:
		return (erx_irq_create(boot->budget.raw, 0, ERX_IRQ_SOFT, 0, &program->bell));
	case ERX_PROGRAM_DATA_CREATE:
		return (erx_mem_create(boot->budget.raw, program->spec.slots * ERX_PROG_DATA_SLOT_BYTES, 0,
		    &program->data));
	case ERX_PROGRAM_BUDGET_CREATE:
		return (erx_budget_create(boot->budget.raw, ERX_BUDGET_ELASTIC, program->spec.guarantee,
		    program->spec.cap, &program->budget));
	case ERX_PROGRAM_GROUP_CREATE:
		return (erx_group_create(program->budget, boot->spaces_group.raw, &program->group));
	case ERX_PROGRAM_IRQ_CREATE:
		return (erx_irq_create(boot->budget.raw, 0, ERX_IRQ_SOFT, 0, &program->irq));
	case ERX_PROGRAM_SINK_REGISTER:
		return (erx_event_register_port(driver_mk_port(program->port), 0, &program->sink));
	case ERX_PROGRAM_IRQ_BIND:
		return (erx_irq_bind(program->irq, ERX_CAP_SELF, program->sink));
	case ERX_PROGRAM_GATE_REGISTER_ANCHOR:
		return (erx_gate_worker_register(program->anchor_label, program->irq));
	case ERX_PROGRAM_GATE_REGISTER_IMAGE:
		return (erx_gate_worker_register(program->image_label, program->irq));
	case ERX_PROGRAM_ANCHOR_CREATE:
		return (erx_space_create(program->budget, ERX_CAP_SELF, erx_gate_worker_handle(),
		    program->anchor_label, 0, PROGRAM_CAP_LIMIT, &program->anchor));
	case ERX_PROGRAM_IMAGE_CREATE:
		return (erx_space_create(program->budget, program->anchor, erx_gate_worker_handle(),
		    program->image_label, 0, PROGRAM_CAP_LIMIT, &program->image));
	case ERX_PROGRAM_IMAGE_MAP:
		status = release_index(program, &index);
		if (status != ERX_OK)
			return (status);
		return (erx_image_map(program->image, boot->release.raw, index, &program->pc));
	case ERX_PROGRAM_INSTALL:
		return (install(program));
	case ERX_PROGRAM_BELL_BIND:
		/*
		 * The channel's label is the session's side's value in the program's table, the
		 * program's peer side, which both parties know from the install.
		 */
		return (erx_irq_bind(program->bell, program->group, program->installed[ERX_PROGRAM_ARG_PEER_SIDE]));
	case ERX_PROGRAM_THREAD_CREATE:
		first_registers(program);
		return (erx_thread_create(program->budget, program->image, program->group,
		    ERX_THREAD_CLASS_WORKER, &program->thread));
	case ERX_PROGRAM_THREAD_START:
		return (erx_thread_start(program->thread));
	case ERX_PROGRAM_WRITE:
		/* The offered frame becomes the one written; frame_write writes it. */
		program->frame = program->offered;
		program->frame_len = program->offered_len;
		program->offered = NULL;
		return (ERX_OK);
	case ERX_PROGRAM_THREAD_CLOSE:
		return (close_cap(&program->thread));
	case ERX_PROGRAM_BELL_UNBIND:
		return (erx_irq_bind(program->bell, ERX_CAP_NULL, 0));
	case ERX_PROGRAM_IMAGE_CLOSE:
		return (close_cap(&program->image));
	case ERX_PROGRAM_ANCHOR_DESTROY:
		return (destroy(&program->anchor));
	case ERX_PROGRAM_GATE_UNREGISTER_IMAGE:
		erx_gate_worker_unregister(program->image_label);
		return (ERX_OK);
	case ERX_PROGRAM_GATE_UNREGISTER_ANCHOR:
		erx_gate_worker_unregister(program->anchor_label);
		return (ERX_OK);
	case ERX_PROGRAM_IRQ_UNBIND:
		return (erx_irq_bind(program->irq, ERX_CAP_NULL, 0));
	case ERX_PROGRAM_SINK_UNREGISTER:
		erx_event_unregister(program->sink);
		return (ERX_OK);
	case ERX_PROGRAM_IRQ_CLOSE:
		/* The object is charged to the session's budget, which outlives the program. */
		return (destroy(&program->irq));
	case ERX_PROGRAM_GROUP_CLOSE:
		return (close_cap(&program->group));
	case ERX_PROGRAM_BUDGET_DESTROY:
		return (destroy(&program->budget));
	/* What the session made from its own budget, deleted only after the program's. */
	case ERX_PROGRAM_DATA_DESTROY:
		return (destroy(&program->data));
	case ERX_PROGRAM_BELL_DESTROY:
		return (destroy(&program->bell));
	case ERX_PROGRAM_CHANNEL_UNMAP:
		/* A frame part-written goes with the lane it was written into. */
		frame_drop(program);
		channel_unmap(program);
		return (ERX_OK);
	case ERX_PROGRAM_CHANNEL_DESTROY:
		channel_destroy(program);
		return (ERX_OK);
	case ERX_PROGRAM_REPORT:
		report(program, action.status);
		return (ERX_OK);
	case ERX_PROGRAM_STOP_ANCHOR:
		return (erx_space_stop(program->anchor, action.status));
	case ERX_PROGRAM_DONE:
	case ERX_PROGRAM_CLOSE_PORT:
		break;
	}
	return (ERX_EINVAL);
}

/*
 * Feeds one input to the end and applies what it returns. True when the last action closed
 * the port: the core puts nothing after ERX_PROGRAM_CLOSE_PORT, and the port's stop may
 * already have freed program, so the caller touches it no more. When owner is not NULL it
 * receives the answer to the owner's command the input carries: apply's for THREAD_START or
 * WRITE, or ERX_EINVAL when the end admitted neither.
 */
static bool
end_feed(program_t *program, erx_program_input_t input, int *owner)
{
	erx_program_action_t actions[ERX_PROGRAM_ACTIONS_MAX];
	const size_t count = erx_program_end_next(&program->end, input, actions);

	if (owner != NULL)
		*owner = ERX_EINVAL;
	for (size_t at = 0; at < count; at++) {
		int status;

		if (actions[at].act == ERX_PROGRAM_CLOSE_PORT) {
			(void)driver_failure_eof(program->port);
			return (true);
		}
		status = apply(program, actions[at]);
		if (owner != NULL && (actions[at].act == ERX_PROGRAM_THREAD_START || actions[at].act == ERX_PROGRAM_WRITE))
			*owner = status;
	}
	return (false);
}

/*
 * Writes what fits of the frame being written into the inbound lane, ringing the program's
 * doorbell when the program waits for it. Once the frame's last byte is in, the end gets
 * WRITTEN; when the program's reader page fails the writer's check, BROKEN, and the frame
 * is dropped either way. A put that ran short waits for the program's ring on the session's
 * doorbell, which brings program_ready_input back here. Nothing to write is nothing done.
 * True when the end closed the port, as end_feed's.
 */
static bool
frame_write(program_t *program)
{
	const erx_lane_iov_t iov = { .base = program->frame, .len = program->frame_len };
	const erx_lane_item_t item = { .iov = &iov, .iovcnt = 1, .kind = ERX_REC_FRAME };
	erx_lane_put_t put;
	erx_lane_put_status_t status;

	if (program->frame == NULL)
		return (false);
	memset(&put, 0, sizeof(put));
	status = erx_lane_put_armed(&program->writer, &item, &put);
	/* A failed ring leaves the program waiting, which its end or the owner's close ends. */
	if (put.ring)
		(void)erx_irq_trigger(program->bell);
	if (status == ERX_LANE_PUT_SHORT)
		return (false);
	frame_drop(program);
	/*
	 * CONTROL_SEND's bound keeps the frame within what a put takes, so a put that is
	 * neither done nor short found the program's reader page broken.
	 */
	return (end_feed(program, (erx_program_input_t){
	    .kind = status == ERX_LANE_PUT_DONE ? ERX_PROGRAM_WRITTEN : ERX_PROGRAM_BROKEN }, NULL));
}

/*
 * Opens a program's port and runs its start whole: the spec's form, then the core's run
 * until it is DONE. A form the parse refuses is badarg; any other failure leaves the port
 * open with the run's answer, which CONTROL_STARTED reads.
 */
static ErlDrvData
program_start(ErlDrvPort port, char *command, SysDriverOpts *opts)
{
	program_t *program;
	erx_program_start_t run;
	erx_program_act_t act;
	int result = ERX_OK;

	(void)opts;
	program = driver_alloc(sizeof(*program));
	if (program == NULL)
		return (ERL_DRV_ERROR_GENERAL);
	memset(program, 0, sizeof(*program));
	program->port = port;
	if (!program_open_parse(command, program)) {
		driver_free(program);
		return (ERL_DRV_ERROR_BADARG);
	}
	set_port_control_flags(port, PORT_CONTROL_FLAG_BINARY);
	program->image_label = atomic_fetch_add_explicit(&labels_given, 2, memory_order_relaxed) + 2;
	program->anchor_label = program->image_label - 1;
	erx_program_start_begin(&run, &program->spec, PROGRAM_POOL);
	while ((act = erx_program_start_next(&run, result)) != ERX_PROGRAM_DONE)
		result = apply(program, (erx_program_action_t){ .act = act });
	program->start_error = run.error;
	program->end = erx_program_end_begin();
	return ((ErlDrvData)program);
}

/* The port is closing, by port_close/1, its owner's exit or the end's own close. */
static void
program_stop(ErlDrvData data)
{
	program_t *const program = (program_t *)data;

	if (program->start_error == ERX_OK)
		(void)end_feed(program, (erx_program_input_t){ .kind = ERX_PROGRAM_CLOSE }, NULL);
	driver_free(program);
}

/*
 * The port's IRQ object was delivered, by the program's ring or the gate worker: first
 * writes what now fits of a frame being written, then takes what the gate worker kept for
 * each of the program's two labels and feeds it to the end, a loss first (erx_gate.h), each
 * record as an input of the space its label names. A delivery is a hint, so a take that
 * finds nothing does nothing.
 */
static void
program_ready_input(ErlDrvData data, ErlDrvEvent event)
{
	program_t *const program = (program_t *)data;
	erx_fault_t image[ERX_GATE_SLOT_RECORDS], anchor[ERX_GATE_SLOT_RECORDS];
	uint64_t image_lost, anchor_lost;
	size_t image_count, anchor_count;

	(void)event;
	if (program->start_error != ERX_OK || frame_write(program))
		return;
	image_count = erx_gate_worker_take(program->image_label, image, &image_lost);
	anchor_count = erx_gate_worker_take(program->anchor_label, anchor, &anchor_lost);
	if ((image_lost > 0 || anchor_lost > 0) &&
	    end_feed(program, (erx_program_input_t){ .kind = ERX_PROGRAM_LOST }, NULL))
		return;
	for (size_t at = 0; at < image_count; at++) {
		if (end_feed(program, erx_program_input_of(&image[at], ERX_PROGRAM_SPACE_IMAGE), NULL))
			return;
	}
	for (size_t at = 0; at < anchor_count; at++) {
		if (end_feed(program, erx_program_input_of(&anchor[at], ERX_PROGRAM_SPACE_ANCHOR), NULL))
			return;
	}
}

/*
 * A command's answer into *rbuf: "ok" followed by extra's extra_len bytes when status is
 * ERX_OK, else "e" and the status's name, "eunknown" for a status with none. Its length,
 * or -1 when no binary could be made.
 */
static ErlDrvSSizeT
answer(int status, const uint8_t *extra, size_t extra_len, char **rbuf)
{
	const char *name = status == ERX_OK ? "ok" : erx_status_name(status);
	const size_t prefix = status == ERX_OK ? 0 : 1;
	ErlDrvBinary *bin;
	size_t need;

	if (name == NULL)
		name = "unknown";
	if (status != ERX_OK)
		extra_len = 0;
	need = prefix + strlen(name) + extra_len;
	bin = driver_alloc_binary((ErlDrvSizeT)need);
	if (bin == NULL)
		return (-1);
	if (prefix > 0)
		bin->orig_bytes[0] = 'e';
	memcpy(&bin->orig_bytes[prefix], name, strlen(name));
	if (extra_len > 0)
		memcpy(&bin->orig_bytes[prefix + strlen(name)], extra, extra_len);
	*rbuf = (char *)bin;
	return ((ErlDrvSSizeT)need);
}

/*
 * CONTROL_SEND: copies the frame and offers it to the end, which admits it as WRITE only
 * while the program lives and no other frame is being written; then writes what fits. The
 * frame is the owner's, checked against the program protocol's grammar by
 * erx_program:start/1; here only its size is bounded, and the program checks the rest.
 */
static int
frame_send(program_t *program, const char *buf, size_t len)
{
	int status;

	if (len < 1 || len > ERX_PROG_FRAME_MAX)
		return (ERX_EINVAL);
	program->offered = driver_alloc(len);
	if (program->offered == NULL)
		return (ERX_ENOMEM);
	memcpy(program->offered, buf, len);
	program->offered_len = len;
	/* A SEND closes no port. */
	(void)end_feed(program, (erx_program_input_t){ .kind = ERX_PROGRAM_SEND }, &status);
	if (program->offered != NULL)
		driver_free(program->offered);
	program->offered = NULL;
	return (status);
}

/*
 * The owner's commands. CONTROL_STARTED reads the start's answer, which feeds the end, and
 * the end closes the port here when the program already ended; the answer is built first,
 * since that close frees program. CONTROL_SEND and CONTROL_RUN act only on a program whose
 * start succeeded; the end decides whether each is admitted.
 */
static ErlDrvSSizeT
program_control(ErlDrvData data, unsigned int command, char *buf, ErlDrvSizeT len, char **rbuf, ErlDrvSizeT rlen)
{
	program_t *const program = (program_t *)data;
	uint8_t value[sizeof(uint64_t)];
	ErlDrvSSizeT need;
	int status;

	(void)rlen;
	switch (command) {
	case CONTROL_STARTED:
		if (len != 0)
			return (-1);
		for (size_t at = 0; at < sizeof(value); at++)
			value[at] = (uint8_t)(program->installed[ERX_PROGRAM_INSTALL_DATA] >> (8 * (sizeof(value) - 1 - at)));
		need = answer(program->start_error, value, sizeof(value), rbuf);
		if (need >= 0 && program->start_error == ERX_OK)
			(void)end_feed(program, (erx_program_input_t){ .kind = ERX_PROGRAM_ANSWERED }, NULL);
		return (need);
	case CONTROL_SEND:
		status = program->start_error == ERX_OK ? frame_send(program, buf, len) : ERX_EINVAL;
		need = answer(status, NULL, 0, rbuf);
		/* A put that ends the frame feeds the end, which closes no port at a WRITTEN or a BROKEN. */
		if (status == ERX_OK)
			(void)frame_write(program);
		return (need);
	case CONTROL_RUN:
		if (len != 0)
			return (-1);
		status = ERX_EINVAL;
		if (program->start_error == ERX_OK)
			(void)end_feed(program, (erx_program_input_t){ .kind = ERX_PROGRAM_RUN }, &status);
		return (answer(status, NULL, 0, rbuf));
	default:
		return (-1);
	}
}

ErlDrvEntry erx_program_driver_entry = {
	.start = program_start,
	.stop = program_stop,
	.ready_input = program_ready_input,
	.driver_name = "erx_program",
	.control = program_control,
	.extended_marker = ERL_DRV_EXTENDED_MARKER,
	.major_version = ERL_DRV_EXTENDED_MAJOR_VERSION,
	.minor_version = ERL_DRV_EXTENDED_MINOR_VERSION,
	.driver_flags = ERL_DRV_FLAG_USE_PORT_LOCKING,
};
