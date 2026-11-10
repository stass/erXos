/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 *
 * The lane port driver, erx_lane: one port per connection to another domain, the
 * controller of the connection's distribution entry (docs/design-runtime.md, "Connections
 * in ERTS"; docs/design-domains.md, "The peer").
 *
 * Every callback runs under the port's lock, so each lane has one party here by
 * construction. Output: outputv turns ERTS's pass-through frame ('p', control term,
 * payload) into one lane record (the frame header, control term, payload) and rings the
 * peer's bell when its store crosses the peer's wake. A frame the lane cannot take whole
 * is kept here, its wait published, and the port is marked busy, so ERTS keeps every later
 * frame in the entry's queue.
 *
 * Input: the connection's bell schedules the port's input task (erx_event.c), and the task
 * is the lane's one consumer. It resumes kept output once the peer has read far enough,
 * then takes up to the lane batch allowance of records, each assembled by
 * erx_funnel_asm into the connection's own buffer, judged by erx_funnel_check and handed,
 * as the verdict allows, to erts_net_message, which keeps order per connection. It
 * reschedules itself at its allowance; otherwise its last take publishes the wait, so the
 * peer's next byte rings the bell. Input never waits on output: a frame that can be
 * answered is taken only while the answers the entry holds unsent stay under
 * ERX_LANE_ANSWERS_MAX, and past it the port ends.
 *
 * The finish (port_control 2), which the agent asks for before it ends the port with the
 * reason the connection went down with: the reader fixes the lane's write position once,
 * and the input task takes every whole record before it, while the port writes nothing more
 * into the other lane, so the answers bound does not apply and a frame whose only effect is
 * an answer is dropped and counted; then it sends the agent {Port, erx_lane_finished}. Where
 * the port is in its finish, and what it does for each event, is erx_lane_core.c's pure
 * decision; the callbacks here gather an event's facts and apply that decision. This file
 * is the one caller of erts_net_message (tools/lib/erx/chokepoint_rules/funnel.rb).
 *
 * The control table (docs/design-domains.md, "The control table"), on a domain's system
 * connection only: the system domain's port for it writes each connection-control record
 * into a slot of the table at the end of its own side (port_control 3), from the domain pid
 * alone, and rings the domain's bell; neither the ring nor the entry's queue is touched, so
 * a full lane or a paused port never holds a record back. The domain's port takes every
 * changed slot at the top of each run that takes, before the ring and outside the allowance,
 * into a buffer of one slot's size, and judges and delivers it as a ring's frame.
 */

#ifdef HAVE_CONFIG_H
#include "config.h"
#endif

#include "sys.h"
#include "erl_vm.h"
#include "global.h"
#include "dist.h"
#include "erl_port.h"
#include "erl_port_task.h"
#include "erl_driver.h"
#include "bif.h"

#include "erx/abi.h"
#include "erx/etf.h"
#include "erx/funnel.h"
#include "erx/lane.h"
#include "liberx/backend/api.h"
#include "erx_event.h"
#include "erx_exports.h"
#include "erx_lane_core.h"
#include "erx_lane_drv.h"

/* The pass-through tag ERTS writes before a frame and reads before one (external.c). */
#define PASS_THROUGH		'p'
/* The longest node name a frame carries: an identifier, "@" and a host. */
#define NODE_MAX		255
/*
 * port_control's commands: the counts, erx_dist's run of the input task after setnode/3, and
 * the agent's finish.
 */
#define CONTROL_COUNTS		0
#define CONTROL_KICK		1
#define CONTROL_FINISH		2
#define CONTROL_RECORD		3
#define CONTROL_HOLD		4
/* Room for an over-limit exit's reason behind the held control term (input_too_large). */
#define TOO_LARGE_REASON_MAX	(ERX_FUNNEL_ASM_FIRST - ERX_FUNNEL_ASM_KEEP)

/* The driver's entry, defined at the end of the file; setnode's question compares with it. */
extern ErlDrvEntry erx_lane_driver_entry;

/* The allowance of one run of the input task, -erx lane_batch. */
uint32_t erx_lane_batch = ERX_LANE_BATCH_DEFAULT;
/* -erx test_lane_hold: port_control 4 may hold a port's ring. */
bool erx_lane_test_hold = false;

typedef struct lane_conn {
	ErlDrvPort		 port;
	Port			*prt;
	uint32_t		 label;		/* the bell's, in the event table */
	uint64_t		 peer_bell;
	void			*own_side;	/* writable mapping of the own side */
	const void		*peer_side;	/* read-only mapping of the peer's */
	uint64_t		 own_bytes, peer_bytes;
	erx_lane_writer_t	 writer;
	erx_lane_reader_t	 reader;
	erx_funnel_lane_t	 lane;
	/* The connection's identity, the lane's lookup's: serial 0, which no holder has, until setnode. */
	erx_exports_conn_t	 exports_conn;
	bool			 system;	/* the system connection, which the boot exports go on */
	erx_funnel_limits_t	 limits;
	char			 peer_node[NODE_MAX + 1];
	char			 own_node[NODE_MAX + 1];
	char			 host[NODE_MAX + 1];

	/* Output: a frame the lane has not taken whole; the port is busy while there is one. */
	uint8_t			*out;
	erx_lane_iov_t		 out_iov;
	erx_lane_item_t		 out_item;

	/* Input: the record being assembled. */
	erx_funnel_asm_t	 assembly;
	uint8_t			*in;
	size_t			 in_cap;
	uint8_t			*scratch;
	size_t			 scratch_len;

	/* Where the port is in its finish, and the process that asked for it, told when done. */
	erx_lane_port_state_t	 state;
	ErlDrvTermData		 finisher;

	/*
	 * The control table: ctl_slots slots after the data area of the system domain's side,
	 * which is the own side of the table's writer and the peer side of its reader; no table
	 * when ctl_seq is NULL. ctl_seq holds each slot's seq, the one the writer stored last or
	 * the reader took last. The writer serves only the domain pid, the system domain's
	 * process of pid_number and pid_serial; the reader copies a slot's frame into ctl_in.
	 */
	uint32_t		 ctl_slots;
	uint64_t		*ctl_seq;
	uint8_t			*ctl_in;
	uint32_t		 pid_number, pid_serial;
	uint32_t		 out_size, in_size;
	bool			 ring_held;	/* port_control 4, -erx test_lane_hold only */

	/* What the port did, for erlang:port_control/3 and the tests. */
	uint64_t		 counts[ERX_LANE_COUNTS];
} lane_conn_t;

static void
count(lane_conn_t *conn, erx_lane_count_t which)
{
	conn->counts[which]++;
}

/*
 * The one way the driver asks erx_lane_core.c and applies its answer: the port moves to the
 * next state, and the event's frame or record, when dropped, is counted as dropped_as.
 * Returns the one action left for the caller to do.
 */
static erx_lane_port_do_t
port_decide(lane_conn_t *conn, const erx_lane_port_input_t *input, erx_lane_count_t dropped_as)
{
	const erx_lane_port_next_t next = erx_lane_port_decide(conn->state, input);

	conn->state = next.state;
	if (next.drop)
		count(conn, dropped_as);
	return (next.what);
}

/* Rings the peer's bell; a failed trigger leaves the peer to its next look. */
static void
ring_peer(lane_conn_t *conn)
{
	if (erx_irq_trigger(conn->peer_bell) != ERX_OK)
		count(conn, ERX_LANE_COUNT_RING_FAILED);
}

/* The next run of the input task, through the event table's handles. */
static void
input_schedule(lane_conn_t *conn)
{
	erx_event_schedule_connection(conn->label);
}

/* ------------------------------------------------------------------ output */

/*
 * The length of the control term at the start of term, from its own encoding: the
 * reader's items, counted until the outermost term has all its parts. 0 when it does
 * not end within ERX_CTL_MAX bytes, which no control term ERTS writes does.
 */
static size_t
control_length(const uint8_t *term, size_t len)
{
	erx_etf_reader_t reader;
	erx_etf_item_t item;
	erx_etf_reason_t reason;
	uint64_t pending = 1;

	if (len > ERX_CTL_MAX)
		len = ERX_CTL_MAX;
	if (!erx_etf_reader_init(&reader, term, len))
		return (0);
	while (pending != 0) {
		if (erx_etf_next(&reader, &item, &reason) != ERX_ETF_STEP_ITEM)
			return (0);
		pending--;
		switch (item.kind) {
		case ERX_ETF_TUPLE:	pending += item.count; break;
		case ERX_ETF_LIST:	pending += (uint64_t)item.count + 1; break;
		case ERX_ETF_MAP:	pending += 2 * (uint64_t)item.count; break;
		case ERX_ETF_RECORD:	pending += 2 + 2 * (uint64_t)item.count; break;
		case ERX_ETF_FUN:	pending += 4 + (uint64_t)item.count; break;
		case ERX_ETF_EXPORT:	pending += 3; break;
		default:		break;
		}
	}
	return (reader.pos);
}

/* What writing the kept frame came to. */
typedef enum {
	OUT_DONE,	/* written whole */
	OUT_WAIT,	/* the lane is full; the wait is published */
	OUT_FAILED	/* the lane refused it: the port must end */
} out_t;

/*
 * Writes what the lane takes of the kept frame. When room runs out it publishes the wait
 * (erx_lane_put_armed), so the peer's read past the published need rings this domain's
 * bell, whose input task calls it again.
 */
static out_t
output_kept(lane_conn_t *conn)
{
	erx_lane_put_t put;
	erx_lane_put_status_t status;

	for (;;) {
		status = erx_lane_put(&conn->writer, &conn->out_item, &put);
		if (put.ring)
			ring_peer(conn);
		if (status == ERX_LANE_PUT_DONE)
			return (OUT_DONE);
		if (status != ERX_LANE_PUT_SHORT)
			break;
		status = erx_lane_put_armed(&conn->writer, &conn->out_item, &put);
		if (put.ring)
			ring_peer(conn);
		if (status == ERX_LANE_PUT_DONE)
			return (OUT_DONE);
		if (status != ERX_LANE_PUT_SHORT)
			break;
		if (put.written == 0 && !put.opened)
			return (OUT_WAIT);
	}
	/* Refused or malformed: the frame cannot go, and nothing after it may overtake it. */
	count(conn, ERX_LANE_COUNT_OUT_REFUSED);
	return (OUT_FAILED);
}

static void
output_done(lane_conn_t *conn)
{
	driver_free(conn->out);
	conn->out = NULL;
	count(conn, ERX_LANE_COUNT_SENT);
}

/*
 * One frame from the entry's queue, copied once behind its header, so a frame the lane
 * cannot take whole waits here unchanged while the port is busy. NULL, or the reason the
 * port must end, for the callback to end it with.
 */
static const char *
output_frame(lane_conn_t *conn, ErlIOVec *ev)
{
	uint8_t first[1 + ERX_CTL_MAX];
	size_t first_len, ctl_len, body;
	uint32_t payload;
	uint8_t *frame;

	if (conn->out != NULL || ev->size < 3) {
		/* ERTS writes no frame while the port is busy, and none this short. */
		count(conn, ERX_LANE_COUNT_OUT_REFUSED);
		return ("erx_lane_refused");
	}
	first_len = ev->size < sizeof(first) ? (size_t)ev->size : sizeof(first);
	(void)driver_vec_to_buf(ev, (char *)first, first_len);
	ctl_len = first[0] == PASS_THROUGH ? control_length(first + 1, first_len - 1) : 0;
	body = (size_t)ev->size - 1;
	if (ctl_len == 0 || body > ERX_FRAME_MAX - ERX_FRAME_HEADER_SIZE) {
		/* Not a frame of the fixed flags, or one no lane carries: dropped, counted. */
		count(conn, ERX_LANE_COUNT_OUT_DROPPED);
		return (NULL);
	}
	frame = driver_alloc(ERX_FRAME_HEADER_SIZE + body);
	if (frame == NULL)
		return ("erx_lane_no_memory");
	/* The pass-through byte is copied too, then overwritten by the header's last byte. */
	(void)driver_vec_to_buf(ev, (char *)frame + ERX_FRAME_HEADER_SIZE - 1, (size_t)ev->size);
	payload = (uint32_t)(body - ctl_len);
	frame[0] = (uint8_t)ctl_len;
	frame[1] = (uint8_t)(ctl_len >> 8);
	frame[2] = (uint8_t)(ctl_len >> 16);
	frame[3] = (uint8_t)(ctl_len >> 24);
	frame[4] = (uint8_t)payload;
	frame[5] = (uint8_t)(payload >> 8);
	frame[6] = (uint8_t)(payload >> 16);
	frame[7] = (uint8_t)(payload >> 24);
	conn->out = frame;
	conn->out_iov = (erx_lane_iov_t){ .base = frame, .len = ERX_FRAME_HEADER_SIZE + body };
	conn->out_item = (erx_lane_item_t){ .iov = &conn->out_iov, .iovcnt = 1, .kind = ERX_REC_FRAME };
	switch (output_kept(conn)) {
	case OUT_DONE:
		output_done(conn);
		return (NULL);
	case OUT_WAIT:
		count(conn, ERX_LANE_COUNT_PAUSED);
		set_busy_port(conn->port, 1);
		return (NULL);
	case OUT_FAILED:
		break;
	}
	return ("erx_lane_refused");
}

/*
 * ERTS's output. Once the finish starts the port writes nothing more into the lane: a frame
 * is dropped and counted, lost with the connection as the frames still in the entry's queue
 * are (erx_lane_core.c, decide_output).
 */
static void
lane_outputv(ErlDrvData data, ErlIOVec *ev)
{
	lane_conn_t *const conn = (lane_conn_t *)data;
	const char *failed;

	if (port_decide(conn, &(erx_lane_port_input_t){ .event = ERX_LANE_PORT_OUTPUT },
	    ERX_LANE_COUNT_OUT_DROPPED) != ERX_LANE_DO_WRITE)
		return;
	failed = output_frame(conn, ev);
	if (failed != NULL)
		driver_failure_atom(conn->port, (char *)failed);	/* last: it may free conn */
}

/*
 * The rest of a kept frame, once the peer has read far enough; then ERTS's output goes on.
 * A finishing port keeps the frame unsent, and frees it at its stop.
 */
static const char *
output_resume(lane_conn_t *conn)
{
	if (conn->out == NULL)
		return (NULL);
	if (port_decide(conn, &(erx_lane_port_input_t){ .event = ERX_LANE_PORT_KEPT },
	    ERX_LANE_COUNT_OUT_DROPPED) != ERX_LANE_DO_RESUME)
		return (NULL);
	switch (output_kept(conn)) {
	case OUT_DONE:
		output_done(conn);
		count(conn, ERX_LANE_COUNT_RESUMED);
		set_busy_port(conn->port, 0);
		return (NULL);
	case OUT_WAIT:
		return (NULL);
	case OUT_FAILED:
		break;
	}
	return ("erx_lane_refused");
}

/* ------------------------------------------------------------------- input */

/* The entry and its connection id while the port controls one, else NULL. */
static DistEntry *
conn_entry(lane_conn_t *conn, Uint32 *conn_id)
{
	if (!(erts_atomic32_read_nob(&conn->prt->state) & ERTS_PORT_SFLG_DISTRIBUTION))
		return (NULL);
	*conn_id = (Uint32)(UWord)erts_prtsd_get(conn->prt, ERTS_PRTSD_CONN_ID);
	return ((DistEntry *)erts_prtsd_get(conn->prt, ERTS_PRTSD_DIST_ENTRY));
}

/* Grows the record buffer to want bytes, which erx_funnel_asm_plan bounds by the record. */
static bool
input_grow(lane_conn_t *conn, size_t want)
{
	uint8_t *const grown = erts_realloc_fnf(ERTS_ALC_T_DRV, conn->in, want);

	if (grown == NULL)
		return (false);
	conn->in = grown;
	conn->in_cap = want;
	return (true);
}

/*
 * Grows the funnel's scratch to what judging held bytes of a frame needs, which is
 * proportional to them, not to max_message_heap. The scratch starts at what any control
 * term needs, so a growth that cannot be allocated leaves the control term judged whole and
 * the payload refused as over a limit, as erx_funnel_check refuses one past the word limit.
 */
static void
scratch_grow(lane_conn_t *conn, size_t held)
{
	const size_t want = erx_funnel_check_scratch_bytes(&conn->limits, held);
	void *grown;

	/* SIZE_MAX, an overflow, is never asked of the allocator: held is bounded by the buffer. */
	if (want <= conn->scratch_len || want == SIZE_MAX)
		return;
	/* A fresh block, not a realloc: nothing in the scratch outlives a judgment. */
	grown = driver_alloc(want);
	if (grown == NULL)
		return;
	driver_free(conn->scratch);
	conn->scratch = grown;
	conn->scratch_len = want;
}

/*
 * A frame to judge and act on: the ring's open record, in the record buffer, or a control
 * slot's copy, in ctl_in. len is the record's len, held the bytes of it in buf (fewer only
 * for a ring record in discard mode), cap the bytes buf holds.
 */
typedef struct lane_frame {
	uint8_t		*buf;
	uint32_t	 len;
	size_t		 held;
	size_t		 cap;
} lane_frame_t;

/*
 * The frame ERTS reads: the control term behind a pass-through byte, which overwrites
 * the frame header's last byte once the funnel has judged it, and then the payload.
 */
static void
input_deliver(DistEntry *dep, Uint32 conn_id, uint8_t *buf, size_t len, erx_net_answer_t answer)
{
	buf[ERX_FRAME_HEADER_SIZE - 1] = PASS_THROUGH;
	erts_atomic64_inc_nob(&dep->in);	/* erlang:dist_get_stat/1's count of frames in */
	(void)erts_net_message(NULL, dep, conn_id, NULL, 0, NULL, buf + ERX_FRAME_HEADER_SIZE - 1,
	    len - (ERX_FRAME_HEADER_SIZE - 1), answer);
}

/*
 * An exit whose payload is over a limit arrives with reason {erx_reason_too_large, Bytes},
 * written behind the held control term: the record buffer never shrinks below
 * ERX_FUNNEL_ASM_FIRST, which leaves room for it behind the longest one; a slot's copy
 * without the room drops it.
 */
static void
input_too_large(lane_conn_t *conn, DistEntry *dep, Uint32 conn_id, const lane_frame_t *frame,
    const erx_funnel_verdict_t *verdict)
{
	const size_t at = ERX_FRAME_HEADER_SIZE + verdict->header.ctl_len;
	uint8_t reason[TOO_LARGE_REASON_MAX];
	erx_etf_writer_t writer;
	size_t reason_len;

	erx_etf_writer_init(&writer, reason, sizeof(reason));
	erx_etf_put_tuple(&writer, 2);
	erx_etf_put_atom(&writer, "erx_reason_too_large", 20);
	erx_etf_put_integer(&writer, (int64_t)verdict->header.payload_len);
	if (!erx_etf_writer_done(&writer, &reason_len) || frame->cap < at + reason_len) {
		count(conn, ERX_LANE_COUNT_DROPPED);
		return;
	}
	memcpy(frame->buf + at, reason, reason_len);
	input_deliver(dep, conn_id, frame->buf, at + reason_len, ERX_NET_DELIVER);
	count(conn, ERX_LANE_COUNT_DELIVERED);
}

/* What the verdict table chose for a whole frame, done through the entry's own queue. */
static bool
input_act(lane_conn_t *conn, DistEntry *dep, Uint32 conn_id, const lane_frame_t *frame,
    const erx_funnel_verdict_t *verdict)
{
	const size_t control = ERX_FRAME_HEADER_SIZE + verdict->header.ctl_len;

	switch (verdict->action) {
	case ERX_FUNNEL_DELIVER:
		input_deliver(dep, conn_id, frame->buf, frame->len, ERX_NET_DELIVER);
		count(conn, ERX_LANE_COUNT_DELIVERED);
		return (true);
	case ERX_FUNNEL_DELIVER_IF_LINKED:
		/*
		 * A LINK the peer has no link right for is kept when the target already holds a
		 * link with the sender, as one of this domain's processes makes toward a peer's
		 * process it was sent. That conditional LINK needs a link record the input task can
		 * read (TODO.md); without it the LINK is answered as for an absent target, which is
		 * wrong only when such a link exists: the peer's process then gets an exit of noproc.
		 */
	case ERX_FUNNEL_ANSWER_NOPROC:
		input_deliver(dep, conn_id, frame->buf, control, ERX_NET_NOPROC);
		count(conn, ERX_LANE_COUNT_ANSWERED);
		return (true);
	case ERX_FUNNEL_ANSWER_SPAWN:
		input_deliver(dep, conn_id, frame->buf, control, verdict->cause == ERX_FUNNEL_CAUSE_OVER_LIMIT ?
		    ERX_NET_SPAWN_LIMIT : ERX_NET_SPAWN_UNAUTHORISED);
		count(conn, ERX_LANE_COUNT_ANSWERED);
		return (true);
	case ERX_FUNNEL_TOO_LARGE:
		input_too_large(conn, dep, conn_id, frame, verdict);
		return (true);
	case ERX_FUNNEL_DROP:
		count(conn, ERX_LANE_COUNT_DROPPED);
		return (true);
	case ERX_FUNNEL_MALFORMED:
		break;
	}
	return (false);
}

typedef enum {
	STEP_TOOK,		/* a whole record was taken and acted on, or every changed slot */
	STEP_EMPTY,		/* nothing more is published, and the wait is */
	STEP_BROKEN,		/* the lane or a frame failed a check: nothing more is delivered */
	STEP_NO_MEMORY,		/* the record's buffer could not grow */
	STEP_ANSWERS_UNREAD	/* an answerable frame came past ERX_LANE_ANSWERS_MAX unsent */
} step_t;

/*
 * The bytes the entry's queue holds beyond what the busy limit counts: the answers it has
 * not sent, and any send of this domain's own with no process or from an async_dist one
 * (TODO.md, lane driver residuals). Read under the queue's lock, so the two sizes agree.
 */
static Sint64
answers_unsent(DistEntry *dep)
{
	Sint64 total, counted;

	erts_mtx_lock(&dep->qlock);
	total = (Sint64)erts_atomic_read_nob(&dep->total_qsize);
	counted = (Sint64)erts_atomic_read_nob(&dep->qsize);
	erts_mtx_unlock(&dep->qlock);
	return (total > counted ? total - counted : 0);
}

/*
 * One take where the assembly's plan says: into the buffer, or into skip for what a
 * discarded record does not keep. When nothing is published the take is repeated armed,
 * so the producer rings at the next byte. Rings the peer when a store of rpos crosses its
 * need.
 */
static erx_lane_status_t
input_take(lane_conn_t *conn, const erx_funnel_asm_plan_t *plan, erx_lane_part_t *part)
{
	uint8_t skip[256];
	uint8_t *const into = plan->where == ERX_FUNNEL_ASM_COPY ? conn->in + plan->at : skip;
	const size_t room = plan->where == ERX_FUNNEL_ASM_COPY ? plan->room : sizeof(skip);
	erx_lane_status_t status;

	*part = (erx_lane_part_t){ 0 };
	status = erx_lane_take(&conn->reader, into, room, part);
	if (part->ring)
		ring_peer(conn);
	if (status != ERX_LANE_EMPTY)
		return (status);
	*part = (erx_lane_part_t){ 0 };
	status = erx_lane_take_armed(&conn->reader, into, room, part);
	if (part->ring)
		ring_peer(conn);
	return (status);
}

/*
 * A whole frame judged by the funnel and then acted on, dropped or ending the port as
 * erx_lane_core.c decides. dep is NULL while the port controls no entry, and the core acts
 * on no frame then. The answers' queue is read only for a frame that can be answered, as it
 * costs the queue's lock.
 */
static step_t
frame_judge(lane_conn_t *conn, DistEntry *dep, Uint32 conn_id, const lane_frame_t *frame)
{
	erx_funnel_verdict_t verdict;
	erx_lane_port_do_t what;
	bool answerable;

	scratch_grow(conn, frame->held);
	erx_funnel_check(frame->buf, frame->len, frame->held, &conn->lane, &conn->limits, conn->scratch,
	    conn->scratch_len, &verdict);
	answerable = dep != NULL && verdict.action != ERX_FUNNEL_MALFORMED &&
	    erx_lane_port_answered(verdict.control.op);
	what = port_decide(conn, &(erx_lane_port_input_t){
	    .event = ERX_LANE_PORT_FRAME, .entry = dep != NULL, .action = verdict.action,
	    .op = verdict.control.op,
	    .answers_full = answerable && answers_unsent(dep) >= ERX_LANE_ANSWERS_MAX }, ERX_LANE_COUNT_DROPPED);
	if (what == ERX_LANE_DO_END_MALFORMED)
		return (STEP_BROKEN);
	if (what == ERX_LANE_DO_END_ANSWERS)
		return (STEP_ANSWERS_UNREAD);
	if (what == ERX_LANE_DO_ACT && !input_act(conn, dep, conn_id, frame, &verdict))
		return (STEP_BROKEN);
	return (STEP_TOOK);
}

/*
 * The control table's step, at the top of each run that takes: every slot whose seq moved
 * since the copy is taken once into ctl_in and judged as a ring's frame, so the record is
 * delivered as a message from its sender, the domain pid. A len or zero out of range breaks
 * the lane, as a malformed ring record does. The seq is kept once frame_judge has dealt with
 * the record, acted on or dropped and counted; every other outcome ends the port.
 */
static step_t
table_step(lane_conn_t *conn, DistEntry *dep, Uint32 conn_id)
{
	lane_frame_t frame = { .buf = conn->ctl_in, .cap = ERX_LANE_CTL_SLOT };
	uint64_t seq;
	step_t step;

	if (conn->ctl_in == NULL)
		return (STEP_TOOK);
	for (uint32_t slot = 0; slot < conn->ctl_slots; slot++) {
		switch (erx_lane_ctl_take(conn->peer_side, conn->in_size, conn->ctl_slots, slot, conn->ctl_seq[slot],
		    conn->ctl_in, &frame.len, &seq)) {
		case ERX_LANE_CTL_UNCHANGED:
			continue;
		case ERX_LANE_CTL_MALFORMED:
			return (STEP_BROKEN);
		case ERX_LANE_CTL_REWRITTEN:
			count(conn, ERX_LANE_COUNT_CTL_REWRITTEN);
			break;
		case ERX_LANE_CTL_TOOK:
			break;
		}
		count(conn, ERX_LANE_COUNT_CTL_TAKEN);
		frame.held = frame.len;
		step = frame_judge(conn, dep, conn_id, &frame);
		if (step != STEP_TOOK)
			return (step);
		conn->ctl_seq[slot] = seq;
	}
	return (STEP_TOOK);
}

/* One funnel step: the rest of the open record, or the next one, judged once whole. */
static step_t
input_step(lane_conn_t *conn, DistEntry *dep, Uint32 conn_id)
{
	erx_funnel_asm_plan_t plan;
	erx_lane_part_t part;
	step_t step;

	for (;;) {
		erx_funnel_asm_plan(&conn->assembly, conn->in_cap, &plan);
		if (plan.where == ERX_FUNNEL_ASM_GROW) {
			/* A record dropped for want of memory would lose a send or an exit unseen. */
			if (!input_grow(conn, plan.want))
				return (STEP_NO_MEMORY);
			continue;
		}
		switch (input_take(conn, &plan, &part)) {
		case ERX_LANE_TOOK:
			break;
		case ERX_LANE_EMPTY:
			return (STEP_EMPTY);
		case ERX_LANE_MALFORMED:
			return (STEP_BROKEN);
		}
		switch (erx_funnel_asm_took(&conn->assembly, &plan, &part, conn->in)) {
		case ERX_FUNNEL_ASM_MORE:
			continue;
		case ERX_FUNNEL_ASM_MALFORMED:
			return (STEP_BROKEN);
		case ERX_FUNNEL_ASM_WHOLE:
			break;
		}
		break;
	}
	step = frame_judge(conn, dep, conn_id, &(lane_frame_t){ .buf = conn->in, .len = conn->assembly.frame,
	    .held = conn->assembly.held, .cap = conn->in_cap });
	if (step == STEP_TOOK)
		erx_funnel_asm_next(&conn->assembly);
	return (step);
}

/* The finish's end, once every whole record before the stop is taken: the agent is told. */
static void
finish_tell(lane_conn_t *conn)
{
	ErlDrvTermData message[] = {
		ERL_DRV_PORT, driver_mk_port(conn->port),
		ERL_DRV_ATOM, driver_mk_atom("erx_lane_finished"),
		ERL_DRV_TUPLE, 2
	};

	/* A finisher that has ended is told nothing: the agent's end halts the runtime. */
	(void)erl_drv_send_term(driver_mk_port(conn->port), conn->finisher, message,
	    (int)(sizeof(message) / sizeof(message[0])));
}

/*
 * The input task's frames, up to the allowance, whether or not the entry is busy: input
 * never waits on output, so two domains streaming to each other never hold each other's
 * lanes. Before the port controls an entry it takes nothing, and erx_dist runs it again
 * after setnode/3; a finishing one takes what is before the stop, entry or not. A finishing
 * port's empty take is its finish's end (erx_lane_core.c, decide_empty), and the record the
 * stop cut short, which the reader holds open, is counted as dropped. The control table's
 * changed slots come first, outside the allowance. NULL, or the reason the port must end.
 */
static const char *
input_run(lane_conn_t *conn)
{
	const uint32_t allowance = erx_lane_batch != 0 ? erx_lane_batch : 1;
	Uint32 conn_id = 0;
	DistEntry *const dep = conn_entry(conn, &conn_id);
	step_t step;

	if (port_decide(conn, &(erx_lane_port_input_t){ .event = ERX_LANE_PORT_RUN, .entry = dep != NULL },
	    ERX_LANE_COUNT_DROPPED) != ERX_LANE_DO_TAKE)
		return (NULL);
	step = table_step(conn, dep, conn_id);
	/* A test's hold (port_control 4) leaves the ring for the run after its release. */
	if (step == STEP_TOOK && conn->ring_held)
		return (NULL);
	for (uint32_t steps = 0; step == STEP_TOOK && steps < allowance; steps++)
		step = input_step(conn, dep, conn_id);
	switch (step) {
	case STEP_TOOK:
		input_schedule(conn);	/* at its allowance: the next run takes the rest */
		return (NULL);
	case STEP_EMPTY:
		if (port_decide(conn, &(erx_lane_port_input_t){ .event = ERX_LANE_PORT_EMPTY,
		    .cut = conn->reader.phase == ERX_LANE_IN_BODY }, ERX_LANE_COUNT_DROPPED) == ERX_LANE_DO_TELL)
			finish_tell(conn);
		return (NULL);
	case STEP_BROKEN:
		count(conn, ERX_LANE_COUNT_MALFORMED);
		return ("erx_lane_malformed");
	case STEP_NO_MEMORY:
		return ("erx_lane_no_memory");
	case STEP_ANSWERS_UNREAD:
		return ("erx_lane_answers_unread");
	}
	return (NULL);
}

/* ------------------------------------------------------------- the driver */

/* The input task, which the bell, the allowance, output and erx_dist schedule. */
static void
lane_ready_input(ErlDrvData data, ErlDrvEvent event)
{
	lane_conn_t *const conn = (lane_conn_t *)data;
	const char *failed;

	(void)event;
	failed = output_resume(conn);
	if (failed == NULL)
		failed = input_run(conn);
	if (failed != NULL)
		driver_failure_atom(conn->port, (char *)failed);	/* last: it may free conn */
}

/* Maps a side: the own side writable, the peer's read-only. 0 when it cannot. */
static uint64_t
side_map(uint64_t mem, uint64_t bytes, uint32_t prot)
{
	uint64_t addr = 0;

	if (erx_vm_reserve(ERX_CAP_SELF, 0, bytes, 0, &addr) != ERX_OK)
		return (0);
	if (erx_vm_map(ERX_CAP_SELF, addr, bytes, mem, 0, prot) != ERX_OK) {
		(void)erx_vm_release(ERX_CAP_SELF, addr, bytes);
		return (0);
	}
	return (addr);
}

static void
conn_free(lane_conn_t *conn)
{
	if (conn->own_side != NULL)
		(void)erx_vm_release(ERX_CAP_SELF, (uint64_t)(uintptr_t)conn->own_side, conn->own_bytes);
	if (conn->peer_side != NULL)
		(void)erx_vm_release(ERX_CAP_SELF, (uint64_t)(uintptr_t)conn->peer_side, conn->peer_bytes);
	if (conn->out != NULL)
		driver_free(conn->out);
	if (conn->in != NULL)
		erts_free(ERTS_ALC_T_DRV, conn->in);
	if (conn->scratch != NULL)
		driver_free(conn->scratch);
	if (conn->ctl_seq != NULL)
		driver_free(conn->ctl_seq);
	if (conn->ctl_in != NULL)
		driver_free(conn->ctl_in);
	driver_free(conn);
}

/* A connection's values, from the open command. */
typedef struct lane_open {
	uint64_t	 side, peer_side, peer_bell;
	uint32_t	 label, out_size, in_size, peer_id;
	uint32_t	 pid_number, pid_serial, ctl_slots;
	const char	*peer_node;
	size_t		 peer_node_len;
	bool		 system;	/* the system connection, from the boot page: the table's reader */
	bool		 table;		/* the system domain's side of one: the table's writer */
} lane_open_t;

/* One decimal word of at most max, then a space or the end. */
static bool
open_word(const char **at, uint64_t max, uint64_t *value)
{
	const char *p = *at;
	uint64_t v = 0;

	if (*p < '0' || *p > '9')
		return (false);
	for (; *p >= '0' && *p <= '9'; p++) {
		if (v > (max - (uint64_t)(*p - '0')) / 10)
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
 * "erx_lane system", the boot page's system connection, its table's slots and its peer's
 * node name; "erx_lane table Side PeerSide PeerBell Label OutSize InSize PeerId PidNumber
 * PidSerial CtlSlots PeerNode", the system domain's side of domain PeerId's system
 * connection, whose table it writes for the domain pid of PidNumber and PidSerial; or
 * "erx_lane Side PeerSide PeerBell Label OutSize InSize PeerId PeerNode". The node name is
 * checked by copy_name's length and by every frame's sender rule, which compares it whole.
 */
static bool
lane_open_parse(const char *command, lane_open_t *open)
{
	static const char system_word[] = "erx_lane system";
	static const char table_word[] = "erx_lane table ";
	static const char driver_word[] = "erx_lane ";
	const char *at = command;
	uint64_t words[10];
	size_t count = 7;
	bool table = false;

	if (strcmp(at, system_word) == 0) {
		const erx_boot_info_t *const boot = erx_runtime_boot();
		const erx_boot_connection_t *const sys = &boot->system_connection;

		*open = (lane_open_t){ .side = sys->side.raw, .peer_side = sys->peer_side.raw, .peer_bell = sys->peer_bell.raw,
			.label = sys->label, .out_size = sys->out_size, .in_size = sys->in_size, .peer_id = sys->peer,
			.ctl_slots = sys->ctl_slots, .system = true };
		open->peer_node = erx_runtime_system_node(&open->peer_node_len);
		return (open->label != 0 && open->label < ERX_LABEL_SPLIT);
	}
	if (strncmp(at, table_word, sizeof(table_word) - 1) == 0) {
		at += sizeof(table_word) - 1;
		count = 10;
		table = true;
	} else if (strncmp(at, driver_word, sizeof(driver_word) - 1) == 0) {
		at += sizeof(driver_word) - 1;
	} else {
		return (false);
	}
	for (size_t i = 0; i < count; i++)
		if (!open_word(&at, i < 3 ? UINT64_MAX : UINT32_MAX, &words[i]))
			return (false);
	*open = (lane_open_t){ .side = words[0], .peer_side = words[1], .peer_bell = words[2],
		.label = (uint32_t)words[3], .out_size = (uint32_t)words[4], .in_size = (uint32_t)words[5],
		.peer_id = (uint32_t)words[6], .peer_node = at, .peer_node_len = strlen(at), .table = table };
	if (table) {
		open->pid_number = (uint32_t)words[7];
		open->pid_serial = (uint32_t)words[8];
		open->ctl_slots = (uint32_t)words[9];
	}
	return (open->label != 0 && open->label < ERX_LABEL_SPLIT);
}

static bool
copy_name(char *into, const char *from, size_t len)
{
	if (len == 0 || len > NODE_MAX)
		return (false);
	memcpy(into, from, len);
	into[len] = '\0';
	return (true);
}

/*
 * Opens a connection's port: "erx_lane system" for the system connection, whose values
 * are the boot page's, "erx_lane table ..." for the system domain's side of a domain's
 * system connection, or "erx_lane Side PeerSide PeerBell Label OutSize InSize PeerId
 * PeerNode" for one connection_up introduced (lane_open_parse). Maps both sides, the
 * system domain's with its control table, prepares the lane's writer and reader and the
 * table's copies, and registers the bell's label as the connection's sink.
 */
static ErlDrvData
lane_start(ErlDrvPort port, char *command, SysDriverOpts *opts)
{
	lane_open_t open;
	lane_conn_t *conn;
	const Atom *own;
	const byte *name, *at;
	size_t host_off;

	(void)opts;
	if (!lane_open_parse(command, &open))
		return (ERL_DRV_ERROR_BADARG);
	if (erts_this_node->sysname == NIL)
		return (ERL_DRV_ERROR_BADARG);	/* the node is not alive */
	own = atom_tab(atom_val(erts_this_node->sysname));
	name = erts_atom_get_name(own);
	at = memchr(name, (int)'@', (size_t)own->len);
	if (at == NULL)
		return (ERL_DRV_ERROR_BADARG);
	conn = driver_alloc(sizeof(*conn));
	if (conn == NULL)
		return (ERL_DRV_ERROR_GENERAL);
	memset(conn, 0, sizeof(*conn));
	conn->port = port;
	conn->prt = erts_drvport2port(port);
	conn->peer_bell = open.peer_bell;
	conn->label = open.label;
	conn->out_size = open.out_size;
	conn->in_size = open.in_size;
	conn->own_bytes = open.table ? erx_lane_ctl_side_bytes(open.out_size, open.ctl_slots) :
	    erx_lane_side_bytes(open.out_size);
	conn->peer_bytes = open.system ? erx_lane_ctl_side_bytes(open.in_size, open.ctl_slots) :
	    erx_lane_side_bytes(open.in_size);
	if (open.system || open.table) {
		conn->ctl_slots = open.ctl_slots;
		conn->pid_number = open.pid_number;
		conn->pid_serial = open.pid_serial;
		/* One word more, so an empty table has its copies too and needs no case of its own. */
		conn->ctl_seq = driver_alloc(((size_t)open.ctl_slots + 1) * sizeof(*conn->ctl_seq));
		if (conn->ctl_seq == NULL)
			goto fail;
		memset(conn->ctl_seq, 0, ((size_t)open.ctl_slots + 1) * sizeof(*conn->ctl_seq));
	}
	if (open.system) {
		conn->ctl_in = driver_alloc(ERX_LANE_CTL_SLOT);
		if (conn->ctl_in == NULL)
			goto fail;
	}
	host_off = (size_t)(at - name) + 1;
	if (!copy_name(conn->own_node, (const char *)name, (size_t)own->len) ||
	    !copy_name(conn->host, (const char *)name + host_off, (size_t)own->len - host_off) ||
	    !copy_name(conn->peer_node, open.peer_node, open.peer_node_len))
		goto fail;
	conn->limits = (erx_funnel_limits_t){ .host = conn->host, .host_len = strlen(conn->host),
		.max_words = erx_runtime_limits()->max_message_heap, .depth = erx_runtime_limits()->funnel_depth,
		.system = erx_runtime_is_system() };
	erx_funnel_asm_init(&conn->assembly, erx_runtime_limits()->max_frame);
	conn->lane = (erx_funnel_lane_t){ .sender_node = conn->peer_node, .sender_node_len = strlen(conn->peer_node),
		.receiver_node = conn->own_node, .receiver_node_len = strlen(conn->own_node),
		.lookup = erx_exports_lookup, .connection = &conn->exports_conn, .sender_id = open.peer_id,
		.receiver_id = (uint32_t)erts_this_node->creation };
	conn->exports_conn = (erx_exports_conn_t){ .peer = open.peer_id };
	conn->system = open.system;
	conn->scratch_len = ERX_FUNNEL_CTL_SCRATCH;
	conn->scratch = driver_alloc(conn->scratch_len);
	conn->in_cap = ERX_FUNNEL_ASM_FIRST;
	conn->in = erts_alloc_fnf(ERTS_ALC_T_DRV, conn->in_cap);
	if (conn->own_bytes == 0 || conn->peer_bytes == 0 || conn->scratch == NULL || conn->in == NULL)
		goto fail;
	conn->own_side = (void *)(uintptr_t)side_map(open.side, conn->own_bytes, ERX_PROT_RW);
	conn->peer_side = (const void *)(uintptr_t)side_map(open.peer_side, conn->peer_bytes, ERX_PROT_R);
	if (conn->own_side == NULL || conn->peer_side == NULL ||
	    !erx_lane_writer_init(&conn->writer, conn->own_side, conn->peer_side, open.out_size) ||
	    !erx_lane_reader_init(&conn->reader, conn->peer_side, conn->own_side, open.in_size))
		goto fail;
	if (erx_event_register_connection(conn->label, driver_mk_port(port)) != ERX_OK)
		goto fail;
	return ((ErlDrvData)conn);
fail:
	conn_free(conn);
	return (ERL_DRV_ERROR_GENERAL);
}

void
erx_lane_connect(Port *pp, uint64_t serial, uint32_t *peer)
{
	lane_conn_t *conn;

	if (pp->drv_ptr == NULL || pp->drv_ptr->entry != &erx_lane_driver_entry)
		return;
	conn = (lane_conn_t *)pp->drv_data;
	conn->exports_conn.serial = serial;
	*peer = conn->exports_conn.peer;
	/* What every runtime exports to the system domain before its first frame is read. */
	if (conn->system)
		erx_exports_boot(&conn->exports_conn);
}

/* The sink goes first, and with it every input task still scheduled. */
static void
lane_stop(ErlDrvData data)
{
	lane_conn_t *const conn = (lane_conn_t *)data;

	erx_event_unregister_connection(conn->label, conn->port);
	conn_free(conn);
}

/*
 * port_control(Port, 3, [<<Slot:32>>, Ctl, Payload]), on the system domain's side of a
 * domain's system connection, from the domain pid alone: the record whose control term is
 * Ctl and whose payload is Payload, both term_to_binary/1's, written into slot Slot of the
 * domain's control table, its seq one past the last, and the domain's bell rung. badarg,
 * writing nothing, from any other process, on a port with no table to write, for a slot past
 * the table's last, a control term that does not end within ERX_CTL_MAX bytes or a frame
 * longer than ERX_LANE_CTL_SLOT (docs/design-runtime.md, "Control records").
 */
static ErlDrvSSizeT
control_record(lane_conn_t *conn, const char *buf, ErlDrvSizeT len)
{
	const Eterm caller = (Eterm)driver_caller(conn->port);
	const uint8_t *const bytes = (const uint8_t *)buf;
	uint32_t slot;
	size_t ctl_len;

	if (conn->ctl_seq == NULL || conn->ctl_in != NULL || !is_internal_pid(caller) ||
	    internal_pid_number(caller) != conn->pid_number || internal_pid_serial(caller) != conn->pid_serial ||
	    len < 4)
		return (-1);
	slot = (uint32_t)bytes[0] << 24 | (uint32_t)bytes[1] << 16 | (uint32_t)bytes[2] << 8 | bytes[3];
	ctl_len = control_length(bytes + 4, len - 4);
	if (slot >= conn->ctl_slots || ctl_len == 0 ||
	    !erx_lane_ctl_put(conn->own_side, conn->out_size, conn->ctl_slots, slot, conn->ctl_seq[slot] + 1,
	    bytes + 4, ctl_len, bytes + 4 + ctl_len, len - 4 - ctl_len))
		return (-1);
	conn->ctl_seq[slot]++;
	ring_peer(conn);
	return (0);
}

/*
 * port_control(Port, 4, <<Hold>>), a test's only and refused without -erx test_lane_hold:
 * Hold 1 has the port's input task take its control table, if it has one, and leave its
 * ring, so the peer's side fills and pauses while records still arrive, or what the peer
 * published waits for a finish; Hold 0 releases it and runs the task, and so does the
 * finish, which takes every whole record before its position as always. It holds only this
 * domain's own port, so it reaches no other domain.
 */
static ErlDrvSSizeT
control_hold(lane_conn_t *conn, const char *buf, ErlDrvSizeT len)
{
	if (!erx_lane_test_hold || len != 1 || (buf[0] != 0 && buf[0] != 1))
		return (-1);
	conn->ring_held = buf[0] == 1;
	if (!conn->ring_held)
		input_schedule(conn);
	return (0);
}

/*
 * port_control(Port, 0, []): the counts, as 64-bit words. port_control(Port, 1, []): one
 * run of the input task, which erx_dist asks for after setnode/3 makes the port the
 * entry's controller, so frames that arrived before then are taken without a bell.
 * port_control(Port, 2, []): the finish, once; badarg after the first. The reader's one
 * load of the write position is checked as every take's is, and a refusal ends the port
 * at the input task's first take, as a malformed lane always does; a port that controls no
 * entry yet takes every whole record before the stop and drops and counts it.
 */
static ErlDrvSSizeT
lane_control(ErlDrvData data, unsigned int command, char *buf, ErlDrvSizeT len, char **rbuf, ErlDrvSizeT rlen)
{
	lane_conn_t *const conn = (lane_conn_t *)data;
	const ErlDrvSizeT need = ERX_LANE_COUNTS * 8;

	if (command == CONTROL_RECORD)
		return (control_record(conn, buf, len));
	if (command == CONTROL_HOLD)
		return (control_hold(conn, buf, len));
	if (command == CONTROL_KICK) {
		input_schedule(conn);
		return (0);
	}
	if (command == CONTROL_FINISH) {
		if (port_decide(conn, &(erx_lane_port_input_t){ .event = ERX_LANE_PORT_FINISH },
		    ERX_LANE_COUNT_DROPPED) != ERX_LANE_DO_STOP)
			return (-1);
		conn->finisher = driver_caller(conn->port);
		conn->ring_held = false;
		(void)erx_lane_reader_stop(&conn->reader);
		input_schedule(conn);
		return (0);
	}
	if (command != CONTROL_COUNTS)
		return (-1);
	if (rlen < need) {
		*rbuf = driver_alloc(need);
		if (*rbuf == NULL)
			return (-1);
	}
	for (int which = 0; which < ERX_LANE_COUNTS; which++) {
		for (int byte = 0; byte < 8; byte++)
			(*rbuf)[which * 8 + byte] = (char)(conn->counts[which] >> (56 - 8 * byte));
	}
	return (need);
}

ErlDrvEntry erx_lane_driver_entry = {
	.start = lane_start,
	.stop = lane_stop,
	.ready_input = lane_ready_input,
	.driver_name = "erx_lane",
	.control = lane_control,
	.outputv = lane_outputv,
	.extended_marker = ERL_DRV_EXTENDED_MARKER,
	.major_version = ERL_DRV_EXTENDED_MAJOR_VERSION,
	.minor_version = ERL_DRV_EXTENDED_MINOR_VERSION,
	/* ERTS makes only a soft-busy port a distribution controller (dist.c); its output stops while busy. */
	.driver_flags = ERL_DRV_FLAG_USE_PORT_LOCKING | ERL_DRV_FLAG_SOFT_BUSY,
};

/*
 * The domain pid the boot page names, a pid of the system domain's node Node, whose creation
 * is its domain id, PeerId, as erx_dist's creations are; any two words name a pid of another
 * node, as NEW_PID_EXT's do (external.c, dec_pid). An external pid must never name this node:
 * the reader refused a page whose peer is the node itself, and if this node has since taken
 * the peer's name and creation, the BIF answers badarg.
 */
static Eterm
boot_domain_pid(Process *p, Eterm node, const erx_boot_connection_t *sys)
{
	ExternalThing *etp;

	if (node == erts_this_node->sysname && sys->peer == erts_this_node->creation)
		return (THE_NON_VALUE);
	etp = (ExternalThing *)HAlloc(p, EXTERNAL_PID_HEAP_SIZE);
	etp->header = make_external_pid_header();
	etp->next = MSO(p).first;
	etp->node = erts_find_or_insert_node(node, sys->peer, make_boxed(&etp->header));
	etp->data.pid.num = sys->domain_pid_number;
	etp->data.pid.ser = sys->domain_pid_serial;
	MSO(p).first = (struct erl_off_heap_header *)etp;
	return (make_external_pid(etp));
}

/*
 * erx_dist:boot/0, the boot page's identity for erx_dist's listen/2 and acceptor:
 * {DomainId, {PeerId, PeerNode, DomainPid}} for a domain with a system connection, and
 * {DomainId, none} for the system domain, which has none. Its one atom is the system domain's
 * node name, which the domain library wrote and the boot page's reader checked is
 * <name>@<host>.
 */
BIF_RETTYPE
erx_dist_boot_0(BIF_ALIST_0)
{
	const erx_boot_info_t *const boot = erx_runtime_boot();
	const erx_boot_connection_t *const sys = &boot->system_connection;
	size_t node_len;
	const char *const node_name = erx_runtime_system_node(&node_len);
	Eterm system = am_none, *hp;

	if (node_len != 0) {
		const Eterm node = erts_atom_put((const byte *)node_name, (Sint)node_len, ERTS_ATOM_ENC_UTF8, 0);
		Eterm pid;

		if (is_non_value(node))
			BIF_ERROR(BIF_P, SYSTEM_LIMIT);
		pid = boot_domain_pid(BIF_P, node, sys);
		if (is_non_value(pid))
			BIF_ERROR(BIF_P, BADARG);
		hp = HAlloc(BIF_P, 4);
		/* A u32 is a small integer on the 64-bit builds erXos makes. */
		system = TUPLE3(hp, make_small((Uint)sys->peer), node, pid);
	}
	hp = HAlloc(BIF_P, 3);
	BIF_RET(TUPLE2(hp, make_small((Uint)boot->domain_id), system));
}

/* One -erx flag at argv[at], its name next and any value after it; the words it takes, or 0. */
static int
lane_flag(int argc, char **argv, int at)
{
	const char *name = at + 1 < argc ? argv[at + 1] : "";
	const char *digit;
	uint64_t batch = 0;

	if (strcmp(name, "test_lane_hold") == 0) {
		erx_lane_test_hold = true;
		return (2);
	}
	if (strcmp(name, "lane_batch") != 0 || at + 2 >= argc || argv[at + 2][0] == '\0')
		return (0);
	for (digit = argv[at + 2]; *digit != '\0'; digit++) {
		if (*digit < '0' || *digit > '9')
			return (0);
		batch = batch * 10 + (uint64_t)(*digit - '0');
		if (batch > UINT32_MAX)
			return (0);
	}
	if (batch == 0)
		return (0);
	erx_lane_batch = (uint32_t)batch;
	return (3);
}

bool
erx_lane_flags(int *argc, char **argv)
{
	int kept = 1;

	for (int at = 1; at < *argc; ) {
		int took;

		if (strcmp(argv[at], "--") == 0) {
			while (at < *argc)
				argv[kept++] = argv[at++];
			break;
		}
		if (strcmp(argv[at], "-erx") != 0) {
			argv[kept++] = argv[at++];
			continue;
		}
		took = lane_flag(*argc, argv, at);
		if (took == 0)
			return (false);
		at += took;
	}
	*argc = kept;
	argv[kept] = NULL;
	return (true);
}
