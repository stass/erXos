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
 * hands the startup message it builds with it to SEND, which writes it into the
 * channel's inbound lane as room returns, and then starts the thread with RUN;
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
 * A program's pipe ends reach it as hand-offs of the pipe NIF (docs/design-pipes.md,
 * "Hand-offs"), named by number alone: at a start, each number the open command carries,
 * which the start takes after the lease, installs after the program's own copies and binds
 * after the program's doorbell; while the program runs, the one INSTALL names. The driver
 * passes each copy with the rights the NIF gives it, within the most a pipe's copy carries
 * (erx_program_hand_rights), binds the end's doorbell to the program's group with the
 * hand-off's label, lets the hand-off go whatever the installs answered, and answers the
 * values the copies took, in the hand-off's order. A start whose take fails partway lets go
 * what it took and fails whole.
 *
 * A take answers a hand-off only for the program the open command names and only to its
 * owner: the process opening the port at a start, and at an INSTALL the process calling
 * port_control, which must also be the port's owner, since ERTS lets any process of the
 * runtime call port_control on a port it names.
 *
 * A take also takes the port's hold on the program's holder entry, and the port keeps
 * whether one of its takes did (held). Only then does the release let the hold go, after
 * the anchor's destroy ended every image of the program and just before the lease's
 * return, so the pipe server reads the program's gone only once nothing of it runs, and a
 * port that took nothing, such as a failed start under a running program's pid, leaves
 * that program's hold alone.
 *
 * The input task also reads the program's frames from the channel's outbound lane: each whole
 * record passes the funnel's channel mode, then ERTS's safe decode, then the program's credit
 * (erx_program_credit_take), and goes to the owner as {erx_channel, Port, Frame}; a record that
 * fails any of them ends the program with SIGSYS (REFUSED). It takes at most INPUT_ALLOWANCE
 * frames a run and rings its own doorbell for the rest, so a program that writes fast holds a
 * scheduler no longer than a lane port does; a run that holds a fault or exit record of the
 * program first takes every frame written before the record, so none is lost to the
 * channel's unmap at the program's end. It reads nothing once the program is ending.
 * A record is copied whole before it is checked, up to ERX_PROG_FRAME_MAX bytes, and nothing
 * else is kept of it, so a program that writes without end costs the session one frame's
 * buffer and the handler one message per credit.
 *
 * This file is ERTS's one caller of erx_space_create, erx_image_map, erx_thread_create and
 * erx_cap_pass, of erx_space_stop on another space, and of ERTS's decoder of a term's
 * external form, which it calls only in safe mode (tools/lib/erx/chokepoint_rules/program.rb),
 * and of the pipe NIF's take and holder release (tools/lib/erx/chokepoint_rules/pipe.rb).
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
#include "erl_port.h"
#include "erl_driver.h"
#include "external.h"
#include "liberx/backend/api.h"
#include "erx/funnel.h"
#include "erx/lane.h"
#include "erx/release.h"
#include "erx_area.h"
#include "erx_event.h"
#include "erx_gate.h"
#include "erx_pipe.h"
#include "erx_program_core.h"

/*
 * The owner's port_control commands, abi/erx_abi.txt's program_control, which erx/abi.h
 * gives as ERX_PROGRAM_CONTROL_STARTED and so on (program_control() reads them; nothing is
 * defined here). Each answers "ok" or the refusing status's
 * e-prefixed name: STARTED how the start ended, "ok" followed by the data area's value in
 * the program's table, 8 bytes big-endian, then for each hand-off the open command names, in
 * its order, the count of its copies, 4 bytes, and the value each copy took, 8 bytes each;
 * SEND the frame it carries, which the driver writes into the inbound lane as room returns,
 * or "busy" while an earlier frame is still being written (send_parse has its payload); RUN,
 * with no payload, the first thread's start; STOP, with a status of 8 bytes big-endian, the
 * anchor's stop with that status; INSTALL, with a hand-off's number of 8 bytes, its install
 * into the running program, "ok" followed by the value each copy took, 8 bytes each. Every
 * word is big-endian.
 */
/* What end_feed hands back for a SEND the end found busy: no status is positive. */
#define SEND_BUSY		1
/* The frames one run of the input task takes before it rings for the next run. */
#define INPUT_ALLOWANCE		16
/*
 * The due notices a program's credit holds (docs/design-programs.md, "Credit"): {closed} ones
 * by two for each descriptor a program holds, since a socketpair gives two pipe ends, so
 * every startup message the grammar accepts fits; and {drained} ones by ERX_PIPES_QUOTA, the
 * most any session's pipes quota may be, which bounds the gone writers of the read ends the
 * program holds.
 */
#define CLOSED_MAX		(2u * ERX_PROG_FDS_MAX)
/*
 * The capabilities the program's anchor may hold, ERX_PROGRAM_CAP_LIMIT, and its image's: the
 * image's table takes the install's ERX_PROGRAM_INSTALLS, every copy of the hand-offs the start
 * takes and of those INSTALL passes while the program runs, and the program's own, so it is
 * made with the kernel's largest table, ERX_CAPS_MAX, which the backend grows only as it fills
 * (abi/erx_abi.txt, program_cap_limit).
 */
#define PROGRAM_IMAGE_CAP_LIMIT	ERX_CAPS_MAX
_Static_assert(ERX_PROGRAM_INSTALLS <= ERX_PROGRAM_CAP_LIMIT, "the install fits the anchor's table");
_Static_assert(ERX_PROGRAM_INSTALLS <= PROGRAM_IMAGE_CAP_LIMIT, "the install fits the image's table");
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
	erx_area_lease_t	*lease;		/* the window's buffer, from its take to its return */
	uint64_t		pc;		/* the image's entry, from erx_image_map */
	/* What the install made of each copy: its value in the image's table, by install index. */
	uint64_t		installed[ERX_PROGRAM_INSTALLS];
	/*
	 * The pipe hand-offs the open command names, in its order: each one's number, the
	 * hand-off taken, from its take until hands_let_go, and the count of its copies.
	 * hand_values holds the value each of their copies took in the image's table,
	 * hand_copies of them in the hand-offs' order, which STARTED answers. Only a HANDS_TAKE
	 * that took every hand-off sets the counts, with hand_values made for their sum, so
	 * every count is 0 unless hand_values holds hand_copies values. held is whether a take of
	 * this port took the port's hold on the program's holder entry, which HOLD_RELEASE then
	 * lets go.
	 */
	uint32_t		hand_count;
	struct {
		uint64_t	number;
		erx_pipe_hand_t	*taken;
		uint32_t	copies;
	}			hand[ERX_PROG_FDS_MAX];
	uint64_t		*hand_values;
	size_t			hand_copies;
	bool			held;
	/*
	 * The inbound lane's writer, ready once the channel is mapped, and the one frame it
	 * writes, NULL but between a WRITE and the frame's WRITTEN or BROKEN; offered is
	 * SEND's copy while the end decides on it.
	 */
	erx_lane_writer_t	writer;
	uint8_t			*frame;
	size_t			frame_len;
	uint8_t			*offered;
	size_t			 offered_len;
	/*
	 * The outbound lane's reader, ready while mapped is, and the record it copies: in, of
	 * in_len bytes with in_have taken, NULL between records.
	 */
	erx_lane_reader_t	reader;
	bool			mapped;
	uint8_t			*in;
	size_t			in_len;
	size_t			in_have;
	/* The program's credit, over due[CLOSED_MAX + ERX_PIPES_QUOTA]. */
	erx_program_credit_t	credit;
	erx_program_notice_t	*due;
} program_t;

/*
 * The funnel's scratch for channel records, made once for the session at the first record and
 * shared by every program's port under scratch_lock (docs/design-domains.md, "Channel mode").
 */
static ErlDrvMutex	*scratch_lock;
static void		*scratch;
static size_t		 scratch_len;

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
 * "erx_program Pid Guarantee Cap Slots Lease Pages Hands Number... Image", as
 * erx_program:start/1 writes it: decimal words, Lease and Pages 0 for a program given no
 * window's buffer, Hands of them the numbers of the pipe hand-offs the program inherits, at
 * most ERX_PROG_FDS_MAX, one for each descriptor, then the image's path, the rest of the
 * command. Only the form is checked here; the core checks the spec's values whole.
 */
static bool
program_open_parse(const char *command, program_t *program)
{
	static const char name[] = "erx_program ";
	const char *at = command;
	uint64_t pid, hands;
	size_t len;

	if (strncmp(at, name, sizeof(name) - 1) != 0)
		return (false);
	at += sizeof(name) - 1;
	if (!open_word(&at, &pid) || !open_word(&at, &program->spec.guarantee) ||
	    !open_word(&at, &program->spec.cap) || !open_word(&at, &program->spec.slots) ||
	    !open_word(&at, &program->spec.lease) || !open_word(&at, &program->spec.lease_pages) ||
	    !open_word(&at, &hands) || pid > (uint64_t)INT64_MAX || hands > ERX_PROG_FDS_MAX)
		return (false);
	program->hand_count = (uint32_t)hands;
	for (uint32_t at_hand = 0; at_hand < program->hand_count; at_hand++) {
		if (!open_word(&at, &program->hand[at_hand].number))
			return (false);
	}
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
		if (entry->kind != ERX_ENTRY_DIRECTORY &&
		    entry->path_length == program->spec.image_len &&
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

	program->mapped = false;
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
 * and the lanes' writer and reader over them: the session's side holds the inbound ring and
 * the outbound reader page, the program's side the outbound ring and the inbound reader
 * page, and the size is the ABI's.
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
	    (const void *)(uintptr_t)program->side_addr[PROGRAM_SIDE], ERX_PROGRAM_LANE) ||
	    !erx_lane_reader_init(&program->reader, (const void *)(uintptr_t)program->side_addr[PROGRAM_SIDE],
	    (void *)(uintptr_t)program->side_addr[SESSION_SIDE], ERX_PROGRAM_LANE)) {
		channel_unmap(program);
		return (ERX_EINVAL);
	}
	program->mapped = true;
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

/* Drops the record being read, if any. */
static void
record_drop(program_t *program)
{
	if (program->in != NULL)
		driver_free(program->in);
	program->in = NULL;
	program->in_len = program->in_have = 0;
}

/* Item item of the next erx_cap_pass: a copy of cap, never a move, carrying rights. */
static void
pass_item(uint32_t item, uint64_t cap, uint32_t rights)
{
	erx_utcb_t *const utcb = erx_utcb_self();
	uint64_t desc = 0;

	(void)erx_msg_item_desc_rights_set(&desc, rights);
	(void)erx_msg_item_desc_move_set(&desc, false);
	(void)erx_utcb_mr_store(utcb, 2 * item, desc);
	(void)erx_utcb_mr_store(utcb, 2 * item + 1, cap);
}

/* Passes the count items pass_item stored into image's table, and reads each one's value there. */
static int
pass_items(uint64_t image, uint32_t count, uint64_t values[])
{
	erx_utcb_t *const utcb = erx_utcb_self();
	const int status = erx_cap_pass(ERX_CAP_SELF, image, count);

	if (status != ERX_OK)
		return (status);
	for (uint32_t item = 0; item < count; item++)
		(void)erx_utcb_mr_load(utcb, 2 * item + 1, &values[item]);
	return (ERX_OK);
}

/*
 * Passes the program's copies into the image's table, each with the rights the core gives
 * its index, in the passes the core sizes, and keeps the value each copy took there. A
 * pass refused partway leaves copies in the image's table, which go with the image.
 */
static int
install(program_t *program)
{
	uint64_t handles[ERX_PROGRAM_INSTALLS] = {
		[ERX_PROGRAM_ARG_BUDGET] = program->budget,
		[ERX_PROGRAM_ARG_GROUP] = program->group,
		[ERX_PROGRAM_ARG_DOORBELL] = program->irq,
		[ERX_PROGRAM_INSTALL_DATA] = program->data,
	};
	uint32_t count;

	for (uint32_t side = 0; side < CHANNEL_SIDES; side++)
		handles[channel_sides[side]] = program->side[side];
	for (uint32_t first = 0; (count = erx_program_pass_batch(first, ERX_PROGRAM_INSTALLS)) > 0;
	    first += count) {
		int status;

		for (uint32_t item = 0; item < count; item++)
			pass_item(item, handles[first + item], erx_program_install_rights(first + item));
		status = pass_items(program->image, count, &program->installed[first]);
		if (status != ERX_OK)
			return (status);
	}
	return (ERX_OK);
}

/*
 * Passes a hand-off's copies into the image's table in its order, each with the rights the
 * NIF gives it within what a pipe's copy may carry, and writes the value each took into
 * values[0, count). A pass refused partway leaves the earlier copies in the image's table
 * unnamed until the image ends (docs/design-pipes.md, "Hand-offs").
 */
static int
hand_pass(uint64_t image, const erx_pipe_hand_t *hand, uint64_t values[])
{
	const uint32_t copies = erx_pipe_hand_count(hand);
	uint32_t count;

	for (uint32_t first = 0; (count = erx_program_pass_batch(first, copies)) > 0; first += count) {
		int status;

		for (uint32_t item = 0; item < count; item++) {
			uint64_t cap;
			uint32_t rights;

			erx_pipe_hand_copy(hand, first + item, &cap, &rights);
			pass_item(item, cap, erx_program_hand_rights(rights));
		}
		status = pass_items(image, count, &values[first]);
		if (status != ERX_OK)
			return (status);
	}
	return (ERX_OK);
}

/* Binds the doorbell of the end a hand-off gives, if it gives one, to group with its label. */
static int
hand_bind(const erx_pipe_hand_t *hand, uint64_t group)
{
	uint64_t bell, label;

	if (!erx_pipe_hand_bell(hand, &bell, &label))
		return (ERX_OK);
	return (erx_irq_bind(bell, group, label));
}

/* Lets go every hand-off the port still holds; each is the driver's to let go once. */
static void
hands_let_go(program_t *program)
{
	for (uint32_t at = 0; at < program->hand_count; at++) {
		if (program->hand[at].taken != NULL)
			erx_pipe_hand_release(program->hand[at].taken);
		program->hand[at].taken = NULL;
	}
}

/*
 * HOLD_RELEASE, an undo just before the lease's return: lets go what the port still holds
 * of the program's hand-offs, then, if one of its takes took it, the port's hold on the
 * program's holder entry, after which no take for the program succeeds. A port that took
 * nothing lets nothing go, so it never ends the hold of a program another port runs.
 */
static void
hold_release(program_t *program)
{
	hands_let_go(program);
	if (program->held)
		erx_pipe_holder_release((uint64_t)program->spec.pid);
	program->held = false;
}

/*
 * Takes hand-off number for the program the open command names, as caller. A take that
 * answers a hand-off also holds the port's hold on the program's holder entry, so this, the
 * driver's one take, records that the port has it (held) for HOLD_RELEASE to let go.
 */
static erx_pipe_hand_t *
hand_take(program_t *program, uint64_t number, ERL_NIF_TERM caller)
{
	erx_pipe_hand_t *const hand = erx_pipe_hand_take(number, (uint64_t)program->spec.pid, caller);

	if (hand != NULL)
		program->held = true;
	return (hand);
}

/*
 * HANDS_TAKE: takes each hand-off the open command names for the program its pid names, as
 * the process opening the port, driver_connected while the start runs, and makes room for
 * the value of each of their copies. ERX_EINVAL for a hand-off the NIF refuses, the same
 * number twice among them, or one it answers with more copies than any hand-off holds;
 * ERX_ENOMEM. A step that fails makes nothing, so this one lets go what it took, and the
 * port's hold, itself, and records no copies.
 */
static int
hands_take(program_t *program)
{
	const ERL_NIF_TERM opener = (ERL_NIF_TERM)driver_connected(program->port);
	size_t copies = 0;
	int status = ERX_OK;

	for (uint32_t at = 0; status == ERX_OK && at < program->hand_count; at++) {
		erx_pipe_hand_t *const hand = hand_take(program, program->hand[at].number, opener);

		if (hand == NULL) {
			status = ERX_EINVAL;
			break;
		}
		program->hand[at].taken = hand;
		if (erx_pipe_hand_count(hand) > ERX_PIPE_HAND_COPIES_MAX)
			status = ERX_EINVAL;
		else
			copies += erx_pipe_hand_count(hand);
	}
	/* At most ERX_PROG_FDS_MAX hand-offs of ERX_PIPE_HAND_COPIES_MAX copies: no product overflows. */
	if (status == ERX_OK && copies > 0 &&
	    (program->hand_values = driver_alloc(copies * sizeof(uint64_t))) == NULL)
		status = ERX_ENOMEM;
	if (status != ERX_OK) {
		hold_release(program);
		return (status);
	}
	for (uint32_t at = 0; at < program->hand_count; at++)
		program->hand[at].copies = erx_pipe_hand_count(program->hand[at].taken);
	program->hand_copies = copies;
	return (ERX_OK);
}

/*
 * HANDS_INSTALL: each hand-off's copies after the program's own, in the open command's
 * order. A hand-off of no copies passes nothing, and hand_values is NULL when none has any.
 */
static int
hands_install(program_t *program)
{
	size_t first = 0;

	for (uint32_t at = 0; at < program->hand_count; at++) {
		int status;

		if (program->hand[at].copies == 0)
			continue;
		status = hand_pass(program->image, program->hand[at].taken, &program->hand_values[first]);
		if (status != ERX_OK)
			return (status);
		first += program->hand[at].copies;
	}
	return (ERX_OK);
}

/* HANDS_BIND: each hand-off's doorbell to the program's group, before its first thread runs. */
static int
hands_bind(program_t *program)
{
	for (uint32_t at = 0; at < program->hand_count; at++) {
		const int status = hand_bind(program->hand[at].taken, program->group);

		if (status != ERX_OK)
			return (status);
	}
	return (ERX_OK);
}

/*
 * Takes the lease the spec names, for this port's owner, which erx_program:start/1 made
 * the lease's holder by calling it itself (docs/design-display.md, "The pixel area").
 * A spec that names none takes nothing. The area NIF answers no lease for a number with
 * no held lease, another holder's or another length's, and the start fails with einval.
 */
static int
lease_take(program_t *program)
{
	if (program->spec.lease == 0)
		return (ERX_OK);
	program->lease = erx_area_lease_take(program->spec.lease, (ERL_NIF_TERM)driver_connected(program->port),
	    program->spec.lease_pages);
	return (program->lease == NULL ? ERX_EINVAL : ERX_OK);
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

/* {erx_channel_room, Port} to the port's owner: the owed frame may be sent again. */
static void
room(program_t *program)
{
	ErlDrvTermData message[] = {
		ERL_DRV_ATOM, driver_mk_atom("erx_channel_room"),
		ERL_DRV_PORT, driver_mk_port(program->port),
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
	case ERX_PROGRAM_LEASE_TAKE:
		return (lease_take(program));
	case ERX_PROGRAM_HANDS_TAKE:
		return (hands_take(program));
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
		    program->anchor_label, 0, ERX_PROGRAM_CAP_LIMIT, &program->anchor));
	case ERX_PROGRAM_IMAGE_CREATE:
		return (erx_space_create(program->budget, program->anchor, erx_gate_worker_handle(),
		    program->image_label, 0, PROGRAM_IMAGE_CAP_LIMIT, &program->image));
	case ERX_PROGRAM_LEASE_MAP:
		return (program->lease == NULL ? ERX_OK : erx_area_lease_map(program->lease, program->image));
	case ERX_PROGRAM_IMAGE_MAP:
		status = release_index(program, &index);
		if (status != ERX_OK)
			return (status);
		return (erx_image_map(program->image, boot->release.raw, index, &program->pc));
	case ERX_PROGRAM_INSTALL:
		return (install(program));
	case ERX_PROGRAM_HANDS_INSTALL:
		return (hands_install(program));
	case ERX_PROGRAM_HANDS_BIND:
		return (hands_bind(program));
	case ERX_PROGRAM_BELL_BIND:
		/* The channel's fixed label, which no pipe end's label equals (abi/protocols/prog.txt). */
		return (erx_irq_bind(program->bell, program->group, ERX_PROG_CHANNEL_LABEL));
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
	case ERX_PROGRAM_BUSY:
		return (SEND_BUSY);
	case ERX_PROGRAM_ROOM:
		room(program);
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
		/* A frame part-written or part-read goes with the lane it was in. */
		frame_drop(program);
		record_drop(program);
		channel_unmap(program);
		return (ERX_OK);
	case ERX_PROGRAM_LEASE_RETURN:
		if (program->lease != NULL)
			erx_area_lease_return(program->lease);
		program->lease = NULL;
		return (ERX_OK);
	case ERX_PROGRAM_CHANNEL_DESTROY:
		channel_destroy(program);
		return (ERX_OK);
	case ERX_PROGRAM_HOLD_RELEASE:
		hold_release(program);
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
 * receives the answer to the owner's command the input carries: apply's for THREAD_START,
 * WRITE or BUSY, ERX_OK for a STOP the end acted on, or ERX_EINVAL when the end admitted
 * none.
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
		if (owner != NULL && (actions[at].act == ERX_PROGRAM_THREAD_START || actions[at].act == ERX_PROGRAM_WRITE ||
		    actions[at].act == ERX_PROGRAM_BUSY || (input.kind == ERX_PROGRAM_STOP && actions[at].act == ERX_PROGRAM_STOP_ANCHOR)))
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
	erx_program_input_t input;
	erx_lane_put_t put;
	erx_lane_put_status_t status;

	if (program->frame == NULL)
		return (false);
	memset(&put, 0, sizeof(put));
	status = erx_lane_put_armed(&program->writer, &item, &put);
	/* A failed ring leaves the program waiting, which its end or the owner's close ends. */
	if (put.ring)
		(void)erx_irq_trigger(program->bell);
	switch (status) {
	case ERX_LANE_PUT_SHORT:
		return (false);
	case ERX_LANE_PUT_DONE:
		input = (erx_program_input_t){ .kind = ERX_PROGRAM_WRITTEN };
		break;
	case ERX_LANE_PUT_MALFORMED:
		input = (erx_program_input_t){ .kind = ERX_PROGRAM_BROKEN };
		break;
	case ERX_LANE_PUT_REFUSED:
	default:
		/*
		 * SEND's bound keeps every frame within what a put takes, so a refusal is
		 * the session's own error: the program is killed, not blamed with SIGSYS.
		 */
		input = (erx_program_input_t){ .kind = ERX_PROGRAM_STOP, .status = ERX_PROGRAM_KILLED };
		break;
	}
	frame_drop(program);
	return (end_feed(program, input, NULL));
}
_Static_assert(ERX_PROG_FRAME_MAX <= ERX_FRAME_MAX, "a put takes every frame SEND admits");

/*
 * Takes the next part of the outbound lane: into the record being copied, or its header
 * alone between records. Rings the program when the take freed room it waits for. The
 * lane's own check refuses what the program wrote out of bounds.
 */
static erx_lane_status_t
input_take(program_t *program, erx_lane_part_t *part)
{
	uint8_t *const into = program->in == NULL ? NULL : program->in + program->in_have;
	const size_t room = program->in == NULL ? 0 : program->in_len - program->in_have;
	erx_lane_status_t status;

	*part = (erx_lane_part_t){ 0 };
	status = erx_lane_take(&program->reader, into, room, part);
	if (status == ERX_LANE_EMPTY) {
		/* Nothing new: publish the wait, so the program rings at its next byte. */
		*part = (erx_lane_part_t){ 0 };
		status = erx_lane_take_armed(&program->reader, into, room, part);
	}
	if (part->ring)
		(void)erx_irq_trigger(program->bell);
	return (status);
}

/*
 * {erx_channel, Port, Frame} to the port's owner, Frame the record decoded by ERTS's safe
 * decode, which makes no atom, into a message of its own, sent as a port's message is. The
 * shape is read from the record and spent from the credit first, so a frame outside the
 * credit reaches no process, and every frame read spends credit whether or not it is
 * delivered, which bounds what one run can read. False when the credit or the decode
 * refuses it, and nothing is sent. An owner that is gone, as when the port outlives an owner
 * that unlinked from it and exited, has no use for the frame, which is dropped undecoded
 * once its credit is spent.
 */
static bool
frame_deliver(program_t *program)
{
	Port *const prt = erts_drvport2port(program->port);
	const byte *ext = program->in;
	ErtsHeapFactory factory;
	Process *owner;
	Sint words;
	Eterm frame, *hp;

	if (erx_program_credit_take(&program->credit,
	    erx_program_frame_shape(program->in, program->in_len)) != ERX_PROGRAM_DELIVER)
		return (false);
	if (prt == ERTS_INVALID_ERL_DRV_PORT)
		return (true);
	owner = erts_proc_lookup(ERTS_PORT_GET_CONNECTED(prt));
	if (owner == NULL)
		return (true);
	words = erts_decode_ext_size(program->in, (Uint)program->in_len);
	if (words < 0)
		return (false);
	(void)erts_factory_message_create(&factory, NULL, NULL, (Uint)words + 4);
	frame = erts_decode_ext(&factory, &ext, ERTS_DIST_EXT_BTT_SAFE);
	if (is_non_value(frame))
		return (false);	/* the decode undid the factory */
	if (ext != program->in + program->in_len) {
		erts_factory_undo(&factory);
		return (false);
	}
	hp = erts_produce_heap(&factory, 4, 0);
	frame = TUPLE3(hp, driver_mk_atom("erx_channel"), prt->common.id, frame);
	erts_factory_close(&factory);
	erts_queue_message(owner, 0, factory.message, frame, prt->common.id);
	return (true);
}

/* What the funnel's channel mode found of a whole record. */
typedef enum {
	CHECK_PASSED,		/* within the channel's checks: frame_deliver decides the rest */
	CHECK_REFUSED,		/* outside them: the end's REFUSED */
	CHECK_NO_MEMORY		/* the session could not make the funnel's scratch */
} check_t;

/* Checks the whole record with the funnel's channel mode, over the session's one scratch. */
static check_t
record_check(program_t *program)
{
	const erx_funnel_limits_t limits = { .max_words = erx_runtime_limits()->max_message_heap,
		.depth = erx_runtime_limits()->funnel_depth };
	erx_etf_result_t result;
	erx_etf_verdict_t verdict = ERX_ETF_OVER_LIMIT;
	bool have_scratch;

	erl_drv_mutex_lock(scratch_lock);
	if (scratch == NULL) {
		scratch_len = erx_funnel_channel_scratch_bytes(&limits);
		scratch = driver_alloc(scratch_len);
	}
	have_scratch = scratch != NULL;
	if (have_scratch)
		verdict = erx_funnel_channel(program->in, program->in_len, &limits, scratch, scratch_len, &result);
	erl_drv_mutex_unlock(scratch_lock);
	if (!have_scratch)
		return (CHECK_NO_MEMORY);
	return (verdict == ERX_ETF_ACCEPTED ? CHECK_PASSED : CHECK_REFUSED);
}

/* How input_run left the outbound lane. */
typedef enum {
	INPUT_DONE,	/* empty and armed, or no longer read: the program's end may go on */
	INPUT_MORE,	/* records remain past the allowance, and the port's own ring brings the next run */
	INPUT_CLOSED	/* the end closed the port, as end_feed's true */
} input_t;

/* Feeds the end the input that ends a run of input_run: INPUT_CLOSED when the end closed the port. */
static input_t
input_end(program_t *program, erx_program_input_t input)
{
	return (end_feed(program, input, NULL) ? INPUT_CLOSED : INPUT_DONE);
}

/*
 * The input task's reading of the outbound lane: whole records, each copied, checked and
 * delivered (frame_deliver), while the program runs. A header that is not a frame within
 * ERX_PROG_FRAME_MAX, a lane that fails its checks and a record that fails its check or its
 * delivery are each the end's REFUSED, after which nothing more is read.
 *
 * How far it reads: to_stop, for a reader stopped at a fixed write position
 * (erx_lane_reader_stop), reads to that position, which bounds the read. Otherwise, after
 * INPUT_ALLOWANCE records it rings the port's own doorbell for the rest and answers
 * INPUT_MORE; when that ring fails nothing else would bring the port back for them, so it
 * reads on to the armed take of an empty lane, and the credit, which every record read
 * spends, bounds that read.
 */
static input_t
input_run(program_t *program, bool to_stop)
{
	const erx_program_input_t refused = { .kind = ERX_PROGRAM_REFUSED };
	const erx_program_input_t killed = { .kind = ERX_PROGRAM_STOP, .status = ERX_PROGRAM_KILLED };
	erx_lane_part_t part;
	check_t check;
	bool delivered;

	for (uint32_t frames = 0; program->mapped && program->end.phase == ERX_PROGRAM_RUNNING;) {
		if (!to_stop && frames == INPUT_ALLOWANCE) {
			if (erx_irq_trigger(program->irq) == ERX_OK)
				return (INPUT_MORE);
			/* frames passes the allowance, so the run reads on to the empty lane. */
		}
		switch (input_take(program, &part)) {
		case ERX_LANE_EMPTY:
			return (INPUT_DONE);
		case ERX_LANE_MALFORMED:
			return (input_end(program, refused));
		case ERX_LANE_TOOK:
			break;
		}
		if (part.opened) {
			if (part.kind != ERX_REC_FRAME || part.zero != 0 || part.len == 0 ||
			    part.len > ERX_PROG_FRAME_MAX)
				return (input_end(program, refused));
			program->in = driver_alloc(part.len);
			if (program->in == NULL)
				return (input_end(program, killed));
			program->in_len = part.len;
			continue;
		}
		program->in_have += part.copied;
		if (!part.closed)
			continue;
		frames++;
		check = record_check(program);
		delivered = false;
		if (check == CHECK_PASSED)
			delivered = frame_deliver(program);
		record_drop(program);
		if (!delivered)
			return (input_end(program, check == CHECK_NO_MEMORY ? killed : refused));
	}
	return (INPUT_DONE);
}

/*
 * Opens a program's port and runs its start whole: the spec's form, then the core's run
 * until it is DONE. A form the parse refuses is badarg; any other failure leaves the port
 * open with the run's answer, which STARTED reads.
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
	program->due = driver_alloc(sizeof(*program->due) * (CLOSED_MAX + ERX_PIPES_QUOTA));
	if (program->due == NULL) {
		driver_free(program);
		return (ERL_DRV_ERROR_GENERAL);
	}
	erx_program_credit_init(&program->credit, program->due, CLOSED_MAX, ERX_PIPES_QUOTA);
	set_port_control_flags(port, PORT_CONTROL_FLAG_BINARY);
	program->image_label = atomic_fetch_add_explicit(&labels_given, 2, memory_order_relaxed) + 2;
	program->anchor_label = program->image_label - 1;
	erx_program_start_begin(&run, &program->spec, PROGRAM_POOL);
	while ((act = erx_program_start_next(&run, result)) != ERX_PROGRAM_DONE)
		result = apply(program, (erx_program_action_t){ .act = act });
	/* Installed and bound, or undone: the hand-offs go whatever the start answered. */
	hands_let_go(program);
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
	if (program->hand_values != NULL)
		driver_free(program->hand_values);
	driver_free(program->due);
	driver_free(program);
}

/*
 * The port's IRQ object was delivered, by the program's ring, the gate worker or the input
 * task's own ring at its allowance. A delivery is a hint, so a step that finds nothing does
 * nothing. In order:
 *
 *   1. Writes what now fits of a frame being written (frame_write).
 *   2. Takes what the gate worker kept for each of the program's two labels: faults, exits
 *      and a loss (erx_gate.h).
 *   3. With records in hand, stops the lane's reader at the write position it finds
 *      (erx_lane_reader_stop) and reads every frame up to it, past the allowance; with
 *      none, reads up to the allowance (input_run).
 *   4. Feeds the records to the end, a loss first, each as an input of the space its label
 *      names.
 *
 * Why the read comes between the take and the feed: a frame the program wrote before the
 * fault or exit a record tells of is in the lane before the record was kept, so the read
 * after the take finds it, and the owner has every frame the program wrote before its end
 * is fed. Every record ends the program: a fault, the image's exit or a loss directly, and
 * the anchor's exit by ending the image with it, since a space never outlives its parent.
 * So what the program writes after the stop, as one of its threads may after another
 * faulted, is never read, and the channel's unmap drops it.
 * The stop bounds that read to one lane's bytes.
 */
static void
program_ready_input(ErlDrvData data, ErlDrvEvent event)
{
	program_t *const program = (program_t *)data;
	erx_fault_t image[ERX_GATE_SLOT_RECORDS], anchor[ERX_GATE_SLOT_RECORDS];
	uint64_t image_lost, anchor_lost;
	size_t image_count, anchor_count;
	bool records;

	(void)event;
	if (program->start_error != ERX_OK || frame_write(program))
		return;
	image_count = erx_gate_worker_take(program->image_label, image, &image_lost);
	anchor_count = erx_gate_worker_take(program->anchor_label, anchor, &anchor_lost);
	records = image_count > 0 || anchor_count > 0 || image_lost > 0 || anchor_lost > 0;
	/* A refused lane makes the read's first take MALFORMED, which ends the program. */
	if (records && program->mapped)
		(void)erx_lane_reader_stop(&program->reader);
	if (input_run(program, records) != INPUT_DONE)
		return;
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

/* A command's answer that is text alone, as "busy": its length, or -1 as answer's. */
static ErlDrvSSizeT
answer_text(const char *text, char **rbuf)
{
	const size_t need = strlen(text);
	ErlDrvBinary *const bin = driver_alloc_binary((ErlDrvSizeT)need);

	if (bin == NULL)
		return (-1);
	memcpy(bin->orig_bytes, text, need);
	*rbuf = (char *)bin;
	return ((ErlDrvSSizeT)need);
}

/* A big-endian word of size bytes at at. */
static uint64_t
word_at(const uint8_t *at, size_t size)
{
	uint64_t value = 0;

	for (size_t i = 0; i < size; i++)
		value = value << 8 | at[i];
	return (value);
}

/* Writes value as a big-endian word of size bytes at at: the byte after it. */
static uint8_t *
word_put(uint8_t *at, uint64_t value, size_t size)
{
	for (size_t i = 0; i < size; i++)
		at[i] = (uint8_t)(value >> (8 * (size - 1 - i)));
	return (at + size);
}

/*
 * Each grant of SEND's payload: its kind, ERX_PROGRAM_GRANT_CLOSED or ERX_PROGRAM_GRANT_DRAINED
 * (erx_abi.txt's program_grant), then three words.
 */
#define GRANT_BYTES		(1 + 3 * 4)
/*
 * What precedes the grants: the reply slot, ERX_PROGRAM_SEND_NO_REPLY for none, and the
 * grants' count.
 */
#define SEND_HEAD_BYTES	(1 + 4)

/*
 * SEND's payload, as erx_program:send/2 writes it: the reply slot the frame answers
 * (ERX_PROGRAM_SEND_NO_REPLY for none), the count of its grants, each grant, then the
 * frame's bytes, at least one and at most ERX_PROG_FRAME_MAX. The words are big-endian.
 * The grants, at most CLOSED_MAX + ERX_PIPES_QUOTA of them, more than any send the credit
 * admits, are copied into memory of their own, which the caller frees as send->grants
 * when it is not NULL. ERX_OK, ERX_EINVAL for a payload of another form, or ERX_ENOMEM.
 */
static int
send_parse(const uint8_t *buf, size_t len, erx_program_send_t *send, const uint8_t **frame,
    size_t *frame_len)
{
	erx_program_notice_t *grants = NULL;
	uint64_t count;

	if (len < SEND_HEAD_BYTES)
		return (ERX_EINVAL);
	count = word_at(buf + 1, 4);
	if (count > CLOSED_MAX + ERX_PIPES_QUOTA || len - SEND_HEAD_BYTES <= count * GRANT_BYTES ||
	    len - SEND_HEAD_BYTES - count * GRANT_BYTES > ERX_PROG_FRAME_MAX)
		return (ERX_EINVAL);
	if (count > 0) {
		grants = driver_alloc(sizeof(*grants) * count);
		if (grants == NULL)
			return (ERX_ENOMEM);
	}
	for (uint64_t at = 0; at < count; at++) {
		const uint8_t *const grant = buf + SEND_HEAD_BYTES + at * GRANT_BYTES;
		erx_program_notice_kind_t kind;

		switch (grant[0]) {
		case ERX_PROGRAM_GRANT_CLOSED:
			kind = ERX_PROGRAM_NOTICE_CLOSED;
			break;
		case ERX_PROGRAM_GRANT_DRAINED:
			kind = ERX_PROGRAM_NOTICE_DRAINED;
			break;
		default:
			driver_free(grants);
			return (ERX_EINVAL);
		}
		grants[at] = (erx_program_notice_t){ .kind = kind,
		    .pipe = (uint32_t)word_at(grant + 1, 4), .end = (uint32_t)word_at(grant + 5, 4),
		    .writer = (uint32_t)word_at(grant + 9, 4) };
	}
	*send = (erx_program_send_t){ .grants = grants, .count = (uint32_t)count,
	    .reply = buf[0] == ERX_PROGRAM_SEND_NO_REPLY ? ERX_PROGRAM_NO_REPLY : buf[0] };
	*frame = buf + SEND_HEAD_BYTES + count * GRANT_BYTES;
	*frame_len = len - SEND_HEAD_BYTES - count * GRANT_BYTES;
	return (ERX_OK);
}

/*
 * SEND: checks the payload's form and that the credit admits what its frame gives,
 * copies the frame and offers it to the end, which admits it as WRITE only while the program
 * lives and no other frame is being written, or answers SEND_BUSY while one is. The credit
 * takes the frame's reply and grants only once the end admitted it. The frame is the owner's,
 * built with the program protocol's grammar; here only its size is bounded, and the program
 * checks the rest.
 */
static int
frame_send(program_t *program, const char *buf, size_t len)
{
	erx_program_send_t send = { .grants = NULL };
	const uint8_t *frame;
	size_t frame_len;
	int status;

	status = send_parse((const uint8_t *)buf, len, &send, &frame, &frame_len);
	if (status == ERX_OK && !erx_program_credit_admits(&program->credit, &send))
		status = ERX_EINVAL;
	if (status == ERX_OK && (program->offered = driver_alloc(frame_len)) == NULL)
		status = ERX_ENOMEM;
	if (status == ERX_OK) {
		memcpy(program->offered, frame, frame_len);
		program->offered_len = frame_len;
		/* A SEND closes no port. */
		(void)end_feed(program, (erx_program_input_t){ .kind = ERX_PROGRAM_SEND }, &status);
		if (status == ERX_OK)
			erx_program_credit_sent(&program->credit, &send);
		if (program->offered != NULL)
			driver_free(program->offered);
		program->offered = NULL;
	}
	if (send.grants != NULL)
		driver_free((void *)send.grants);
	return (status);
}

/*
 * STARTED's answer after "ok": the data area's value, then each hand-off's count of copies
 * and their values, into memory of its own, which the caller frees; NULL when there is none.
 * A failed start answers no payload, so only a start that installed every copy answers
 * hand-offs, and the counts it walks are those hand_values was made for.
 */
static uint8_t *
started_values(const program_t *program, size_t *len)
{
	const uint64_t *value = program->hand_values;
	const uint32_t hands = program->start_error == ERX_OK ? program->hand_count : 0;
	uint8_t *bytes, *at;

	*len = sizeof(uint64_t);
	if (hands > 0)
		*len += hands * sizeof(uint32_t) + program->hand_copies * sizeof(uint64_t);
	if ((bytes = driver_alloc(*len)) == NULL)
		return (NULL);
	at = word_put(bytes, program->installed[ERX_PROGRAM_INSTALL_DATA], sizeof(uint64_t));
	for (uint32_t hand = 0; hand < hands; hand++) {
		const uint32_t copies = program->hand[hand].copies;

		at = word_put(at, copies, sizeof(uint32_t));
		for (uint32_t copy = 0; copy < copies; copy++)
			at = word_put(at, *value++, sizeof(uint64_t));
	}
	return (bytes);
}

/*
 * INSTALL: takes hand-off number for the running program as the process calling port_control,
 * which must be the port's owner, passes its copies into the image, binds its doorbell to the
 * program's group, lets it go whatever those answered, and writes the values its copies took
 * into *values, *len bytes of memory of its own, which the caller frees. ERX_EINVAL for a
 * start that failed, a caller that is not the owner, or a hand-off the NIF refuses or answers
 * with more copies than any hand-off holds; ERX_EDEAD once the program is ending; ERX_ENOMEM;
 * or the refusal of a pass or the bind. A failed install names nothing to the program: the
 * owner does not send the frame that would carry the values (docs/design-pipes.md,
 * "Hand-offs").
 */
static int
hand_install(program_t *program, uint64_t number, uint8_t **values, size_t *len)
{
	const ErlDrvTermData caller = driver_caller(program->port);
	erx_pipe_hand_t *hand;
	uint64_t *copies = NULL;
	uint32_t count;
	int status = ERX_OK;

	*values = NULL;
	*len = 0;
	if (program->start_error != ERX_OK || caller != driver_connected(program->port))
		return (ERX_EINVAL);
	if (!erx_program_end_installs(&program->end))
		return (ERX_EDEAD);
	hand = hand_take(program, number, (ERL_NIF_TERM)caller);
	if (hand == NULL)
		return (ERX_EINVAL);
	count = erx_pipe_hand_count(hand);
	if (count > ERX_PIPE_HAND_COPIES_MAX)
		status = ERX_EINVAL;
	if (status == ERX_OK && count > 0 && (copies = driver_alloc(count * sizeof(uint64_t))) == NULL)
		status = ERX_ENOMEM;
	if (status == ERX_OK)
		status = hand_pass(program->image, hand, copies);
	if (status == ERX_OK)
		status = hand_bind(hand, program->group);
	erx_pipe_hand_release(hand);
	if (status == ERX_OK && count > 0 && (*values = driver_alloc((size_t)count * sizeof(uint64_t))) == NULL)
		status = ERX_ENOMEM;
	if (status == ERX_OK)
		*len = (size_t)count * sizeof(uint64_t);
	for (uint32_t copy = 0; status == ERX_OK && copy < count; copy++)
		(void)word_put(*values + copy * sizeof(uint64_t), copies[copy], sizeof(uint64_t));
	if (copies != NULL)
		driver_free(copies);
	return (status);
}

/*
 * The owner's commands. STARTED reads the start's answer, which feeds the end, and
 * the end closes the port here when the program already ended; the answer is built first,
 * since that close frees program. SEND, RUN and STOP act only on a
 * program whose start succeeded; the end decides whether each is admitted. A STOP's status
 * is the one the program's end reports, from 0 to 2^32 - 1.
 */
static ErlDrvSSizeT
program_control(ErlDrvData data, unsigned int command, char *buf, ErlDrvSizeT len, char **rbuf, ErlDrvSizeT rlen)
{
	program_t *const program = (program_t *)data;
	uint8_t *values;
	size_t values_len;
	ErlDrvSSizeT need;
	uint64_t stop;
	int status;

	(void)rlen;
	switch (command) {
	case ERX_PROGRAM_CONTROL_STARTED:
		if (len != 0 || (values = started_values(program, &values_len)) == NULL)
			return (-1);
		need = answer(program->start_error, values, values_len, rbuf);
		driver_free(values);
		if (need >= 0 && program->start_error == ERX_OK)
			(void)end_feed(program, (erx_program_input_t){ .kind = ERX_PROGRAM_ANSWERED }, NULL);
		return (need);
	case ERX_PROGRAM_CONTROL_INSTALL:
		if (len != sizeof(uint64_t))
			return (-1);
		status = hand_install(program, word_at((const uint8_t *)buf, sizeof(uint64_t)), &values, &values_len);
		need = answer(status, values, values_len, rbuf);
		if (values != NULL)
			driver_free(values);
		return (need);
	case ERX_PROGRAM_CONTROL_SEND:
		status = program->start_error == ERX_OK ? frame_send(program, buf, len) : ERX_EINVAL;
		need = status == SEND_BUSY ? answer_text("busy", rbuf) : answer(status, NULL, 0, rbuf);
		/* A put that ends the frame feeds the end, which closes no port at its WRITTEN, BROKEN or STOP. */
		if (status == ERX_OK)
			(void)frame_write(program);
		return (need);
	case ERX_PROGRAM_CONTROL_RUN:
		if (len != 0)
			return (-1);
		status = ERX_EINVAL;
		if (program->start_error == ERX_OK)
			(void)end_feed(program, (erx_program_input_t){ .kind = ERX_PROGRAM_RUN }, &status);
		return (answer(status, NULL, 0, rbuf));
	case ERX_PROGRAM_CONTROL_STOP:
		if (len != sizeof(uint64_t))
			return (-1);
		stop = word_at((const uint8_t *)buf, sizeof(uint64_t));
		status = ERX_EINVAL;
		/* The stop's actions close no port: the image's exit record ends the program. */
		if (program->start_error == ERX_OK && stop <= UINT32_MAX)
			(void)end_feed(program, (erx_program_input_t){ .kind = ERX_PROGRAM_STOP,
			    .status = (int64_t)stop }, &status);
		return (answer(status, NULL, 0, rbuf));
	default:
		return (-1);
	}
}

/* The session's one lock over the funnel's scratch, made at boot as every driver's init runs. */
static int
program_init(void)
{
	scratch_lock = erl_drv_mutex_create("erx_program_scratch");
	return (scratch_lock == NULL ? -1 : 0);
}

ErlDrvEntry erx_program_driver_entry = {
	.init = program_init,
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
