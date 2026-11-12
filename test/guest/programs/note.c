/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

/*
 * The programs suite's program that writes records of its own into its
 * channel's outbound lane (tools/lib/erx/programs.rb, the note cases), so
 * that how it ends is the session's verdict on those records alone
 * (docs/design-runtime.md, "Programs as ports"). argv[1] names the records:
 *
 *   atom	{erx_prog, 1, {closed, 1, Atom}}, Atom an atom no runtime image
 *		holds, which the session's safe decode refuses without making it
 *   bad	a term cut short, which the funnel's channel mode refuses
 *   undue	{erx_prog, 1, {closed, 1, 1}}, a notice the session never made
 *		due, which the program's credit refuses
 *   request	{erx_prog, 1, 0, getpid}, a request on a free slot, which the
 *		session delivers to the port's owner
 *   burst	{erx_prog, 1, S, getpid} for each slot S from 0 to 15, then once
 *		more for slot 0, which is busy, so the credit refuses it
 *
 * Each of the first four writes its one record, rings the session and
 * waits; each but request ends the program with SIGSYS. burst rings nothing
 * and then loads from the null page, as fault.c does, so the session first
 * looks at its records with the page fault's record in hand. Only the first
 * of the two ends decides the status: SIGSYS if the session read every
 * record the program wrote before it faulted, and SIGSEGV if it took the
 * fault before the refused record. The records go through a
 * writer of the program's own over its side of the channel, a raw put that
 * the program-channel-send build check permits here alone: burst must write
 * its records without ringing the session, which liberx's channel send
 * (liberx/program/channel.h) does whenever its store crosses the session's
 * wake. That send writes only when the program calls it, which note never
 * does, so this writer is the only one that writes the lane. A name it does
 * not know ends the program with 2, and a channel it cannot map or write
 * with 3.
 */

#include <stdbool.h>
#include <stddef.h>
#include <string.h>

#include "erx/lane.h"
#include "liberx/backend/api.h"
#include "liberx/program/program.h"

int	main(int, char **, char **);

/* ETF: the version, a 3-tuple, the atom erx_prog, the version 1, a 3-tuple and the atom closed. */
#define NOTICE_HEAD	"\x83\x68\x03\x77\x08" "erx_prog" "\x61\x01\x68\x03\x77\x06" "closed" "\x61\x01"
#define FRESH_ATOM	"erx_program_note_fresh_atom"
_Static_assert(sizeof(FRESH_ATOM) - 1 == 0x1b, "the atom's length byte");
/*
 * ETF: the version, a 4-tuple, the atom erx_prog, the version 1 and a small integer's tag,
 * whose one byte, the slot, comes between REQUEST_HEAD and REQUEST_TAIL, the atom getpid.
 */
#define REQUEST_HEAD	"\x83\x68\x04\x77\x08" "erx_prog" "\x61\x01\x61"
#define REQUEST_TAIL	"\x77\x06" "getpid"

/* Each mode that writes one record, rings the session and waits, by its name. */
#define NOTE(name, record)	{ name, record, sizeof(record) - 1 }
static const struct {
	const char	*name;
	const char	*record;
	size_t		 len;
} notes[] = {
	NOTE("atom", NOTICE_HEAD "\x77\x1b" FRESH_ATOM),
	NOTE("bad", NOTICE_HEAD),
	NOTE("undue", NOTICE_HEAD "\x61\x01"),
	NOTE("request", REQUEST_HEAD "\x00" REQUEST_TAIL),
};

/* The first size bytes of the memory object mem, mapped with prot, or NULL. */
static void *
side_map(uint64_t mem, uint64_t size, uint32_t prot)
{
	uint64_t addr = 0;

	if (erx_vm_reserve(ERX_CAP_SELF, 0, size, 0, &addr) != ERX_OK)
		return (NULL);
	if (erx_vm_map(ERX_CAP_SELF, addr, size, mem, 0, prot) != ERX_OK)
		return (NULL);
	return ((void *)(uintptr_t)addr);
}

/* Maps the program's two sides of its channel and makes the outbound lane's writer over them. */
static bool
writer_open(erx_lane_writer_t *writer)
{
	const erx_prog_self_t *const self = erx_prog_self();
	const uint64_t bytes = erx_lane_side_bytes(ERX_PROGRAM_LANE);
	void *const own = side_map(self->regs[ERX_PROGRAM_ARG_OWN_SIDE], bytes, ERX_PROT_RW);
	const void *const peer = side_map(self->regs[ERX_PROGRAM_ARG_PEER_SIDE], bytes, ERX_PROT_R);

	return (own != NULL && peer != NULL && erx_lane_writer_init(writer, own, peer, ERX_PROGRAM_LANE));
}

/* Writes the record made of iov[0, iovcnt) whole into the outbound lane, without a ring. */
static bool
record_put(erx_lane_writer_t *writer, const erx_lane_iov_t *iov, size_t iovcnt)
{
	const erx_lane_item_t item = { .iov = iov, .iovcnt = iovcnt, .kind = ERX_REC_FRAME };
	erx_lane_put_t put;

	memset(&put, 0, sizeof(put));
	return (erx_lane_put(writer, &item, &put) == ERX_LANE_PUT_DONE);
}

/* Writes the request on slot whole into the outbound lane, without a ring. */
static bool
request_put(erx_lane_writer_t *writer, uint8_t slot)
{
	static const char head[] = REQUEST_HEAD, tail[] = REQUEST_TAIL;
	const erx_lane_iov_t iov[] = {
		{ .base = head, .len = sizeof(head) - 1 },
		{ .base = &slot, .len = 1 },
		{ .base = tail, .len = sizeof(tail) - 1 },
	};

	return (record_put(writer, iov, sizeof(iov) / sizeof(iov[0])));
}

/* The burst's records: a request on every slot, then one more on slot 0, which is still busy. */
static bool
burst(erx_lane_writer_t *writer)
{
	for (uint8_t slot = 0; slot < ERX_PROG_DATA_SLOTS_MAX; slot++) {
		if (!request_put(writer, slot))
			return (false);
	}
	return (request_put(writer, 0));
}

int
main(int argc, char **argv, char **envp)
{
	erx_lane_writer_t writer;

	(void)envp;
	if (argc != 2)
		return (2);
	if (strcmp(argv[1], "burst") == 0) {
		int *volatile null = NULL;

		if (!writer_open(&writer) || !burst(&writer))
			return (3);
		/* A load from the null page, kept by the volatile pointer, ends the program. */
		return (*null);
	}
	for (size_t at = 0; at < sizeof(notes) / sizeof(notes[0]); at++) {
		const erx_lane_iov_t iov = { .base = notes[at].record, .len = notes[at].len };

		if (strcmp(argv[1], notes[at].name) != 0)
			continue;
		if (!writer_open(&writer) || !record_put(&writer, &iov, 1) ||
		    erx_irq_trigger(erx_prog_self()->regs[ERX_PROGRAM_ARG_DOORBELL]) != ERX_OK)
			return (3);
		for (;;)
			;
	}
	return (2);
}
