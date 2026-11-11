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
 * reads the failure with port_control and closes it. The end runs in the input task: the
 * gate worker keeps each exit and fault record of the program's spaces in the port's slot
 * and triggers the port's IRQ object, whose delivery schedules this port's input task,
 * which takes the records and feeds them to the core. Each of the program's two spaces
 * carries a label of its own, so the label a record was kept for says which space it is
 * from. Reading the start's answer and closing the port feed the core too. All of these run
 * under the port's lock, so a port's start, input tasks, control calls and stop follow one
 * another, and the input task first runs after the start returned.
 *
 * This file is ERTS's one caller of erx_space_create, erx_image_map and erx_thread_create,
 * and of erx_space_stop on another space (tools/lib/erx/chokepoint_rules/program.rb).
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
#include "erx/release.h"
#include "erx_event.h"
#include "erx_gate.h"
#include "erx_program_core.h"

/* port_control(Port, 1, []): how the start ended, "ok" or the status's e-prefixed name. */
#define CONTROL_STARTED		1
/* The capabilities each of a program's spaces may hold: it is given none in this package. */
#define PROGRAM_CAP_LIMIT	16u
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

typedef struct {
	ErlDrvPort		port;
	erx_program_spec_t	spec;
	uint8_t			image_path[ERX_PACK_PATH_MAX];
	int			start_error;	/* the start's run's answer */
	erx_program_end_t	end;		/* meaningful once the start answered ERX_OK */
	uint64_t		anchor_label;	/* what the anchor's records are kept under */
	uint64_t		image_label;	/* and the image's */
	/* What the start made, each ERX_CAP_NULL until its step made it. */
	uint64_t		budget;
	uint64_t		group;
	uint64_t		irq;
	uint32_t		sink;		/* the event table's label for the port */
	uint64_t		anchor;
	uint64_t		image;
	uint64_t		thread;
	uint64_t		pc;		/* the image's entry, from erx_image_map */
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
 * "erx_program Pid Guarantee Cap Image", as erx_program:start/1 writes it: three decimal
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
	    !open_word(&at, &program->spec.cap) || pid > (uint64_t)INT64_MAX)
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

/* The image's entry and nothing else in the first thread's starting registers, as erx_thread_create reads them. */
static void
first_registers(uint64_t pc)
{
	erx_thread_start_t start;
	uint64_t words[sizeof(start) / sizeof(uint64_t)];

	memset(&start, 0, sizeof(start));
	start.regs.pc = pc;
	memcpy(words, &start, sizeof(words));
	for (size_t word = 0; word < sizeof(words) / sizeof(words[0]); word++)
		(void)erx_utcb_mr_store(erx_utcb_self(), word, words[word]);
}

/* Destroys an object the start made and closes the session's capability to it. */
static int
destroy(uint64_t *object)
{
	const int status = erx_object_destroy(*object);

	(void)erx_cap_close(*object);
	*object = ERX_CAP_NULL;
	return (status);
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
 * core reads, and any status for the rest, which it does not. The session's budget and
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
	case ERX_PROGRAM_THREAD_CREATE:
		first_registers(program->pc);
		return (erx_thread_create(program->budget, program->image, program->group,
		    ERX_THREAD_CLASS_WORKER, &program->thread));
	case ERX_PROGRAM_THREAD_START:
		return (erx_thread_start(program->thread));
	case ERX_PROGRAM_THREAD_CLOSE:
		return (close_cap(&program->thread));
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
 * already have freed program, so the caller touches it no more.
 */
static bool
end_feed(program_t *program, erx_program_input_t input)
{
	erx_program_action_t actions[ERX_PROGRAM_ACTIONS_MAX];
	const size_t count = erx_program_end_next(&program->end, input, actions);

	for (size_t at = 0; at < count; at++) {
		if (actions[at].act == ERX_PROGRAM_CLOSE_PORT) {
			(void)driver_failure_eof(program->port);
			return (true);
		}
		(void)apply(program, actions[at]);
	}
	return (false);
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
		(void)end_feed(program, (erx_program_input_t){ .kind = ERX_PROGRAM_CLOSE });
	driver_free(program);
}

/*
 * The port's IRQ object was delivered: takes what the gate worker kept for each of the
 * program's two labels and feeds it to the end, a loss first (erx_gate.h), each record as
 * an input of the space its label names. A delivery is a hint, so a take that finds
 * nothing does nothing.
 */
static void
program_ready_input(ErlDrvData data, ErlDrvEvent event)
{
	program_t *const program = (program_t *)data;
	erx_fault_t image[ERX_GATE_SLOT_RECORDS], anchor[ERX_GATE_SLOT_RECORDS];
	uint64_t image_lost, anchor_lost;
	size_t image_count, anchor_count;

	(void)event;
	if (program->start_error != ERX_OK)
		return;
	image_count = erx_gate_worker_take(program->image_label, image, &image_lost);
	anchor_count = erx_gate_worker_take(program->anchor_label, anchor, &anchor_lost);
	if ((image_lost > 0 || anchor_lost > 0) &&
	    end_feed(program, (erx_program_input_t){ .kind = ERX_PROGRAM_LOST }))
		return;
	for (size_t at = 0; at < image_count; at++) {
		if (end_feed(program, erx_program_input_of(&image[at], ERX_PROGRAM_SPACE_IMAGE)))
			return;
	}
	for (size_t at = 0; at < anchor_count; at++) {
		if (end_feed(program, erx_program_input_of(&anchor[at], ERX_PROGRAM_SPACE_ANCHOR)))
			return;
	}
}

/*
 * The start's answer: "ok", or "e" and the failed status's name, "eunknown" for a status
 * with none. Reading a started program's answer feeds the end, which closes the port here
 * when the program already ended; the answer is built first, since that close frees program.
 */
static ErlDrvSSizeT
program_control(ErlDrvData data, unsigned int command, char *buf, ErlDrvSizeT len, char **rbuf, ErlDrvSizeT rlen)
{
	program_t *const program = (program_t *)data;
	const char *name;
	ErlDrvBinary *bin;
	size_t need;

	(void)buf;
	(void)rlen;
	if (command != CONTROL_STARTED || len != 0)
		return (-1);
	name = program->start_error == ERX_OK ? "ok" : erx_status_name(program->start_error);
	if (name == NULL)
		name = "unknown";
	need = (program->start_error == ERX_OK ? 0 : 1) + strlen(name);
	bin = driver_alloc_binary((ErlDrvSizeT)need);
	if (bin == NULL)
		return (-1);
	if (program->start_error == ERX_OK) {
		memcpy(bin->orig_bytes, name, need);
	} else {
		bin->orig_bytes[0] = 'e';
		memcpy(&bin->orig_bytes[1], name, need - 1);
	}
	*rbuf = (char *)bin;
	if (program->start_error == ERX_OK)
		(void)end_feed(program, (erx_program_input_t){ .kind = ERX_PROGRAM_ANSWERED });
	return ((ErlDrvSSizeT)need);
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
