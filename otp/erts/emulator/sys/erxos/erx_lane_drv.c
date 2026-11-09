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
 * ERX_LANE_ANSWERS_MAX, and past it the port ends. This file is the one caller of
 * erts_net_message (tools/lib/erx/chokepoint_rules/funnel.rb).
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
#include "erx_lane_drv.h"

/* The pass-through tag ERTS writes before a frame and reads before one (external.c). */
#define PASS_THROUGH		'p'
/* The longest node name a frame carries: an identifier, "@" and a host. */
#define NODE_MAX		255
/* port_control's commands: the counts, and erx_dist's run of the input task after setnode/3. */
#define CONTROL_COUNTS		0
#define CONTROL_KICK		1
/* Room for an over-limit exit's reason behind the held control term (input_too_large). */
#define TOO_LARGE_REASON_MAX	(ERX_FUNNEL_ASM_FIRST - ERX_FUNNEL_ASM_KEEP)

/* The allowance of one run of the input task, -erx lane_batch. */
uint32_t erx_lane_batch = ERX_LANE_BATCH_DEFAULT;

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

	/* What the port did, for erlang:port_control/3 and the tests. */
	uint64_t		 counts[ERX_LANE_COUNTS];
} lane_conn_t;

static void
count(lane_conn_t *conn, erx_lane_count_t which)
{
	conn->counts[which]++;
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

/* ERTS's output. */
static void
lane_outputv(ErlDrvData data, ErlIOVec *ev)
{
	lane_conn_t *const conn = (lane_conn_t *)data;
	const char *const failed = output_frame(conn, ev);

	if (failed != NULL)
		driver_failure_atom(conn->port, (char *)failed);	/* last: it may free conn */
}

/* The rest of a kept frame, once the peer has read far enough; then ERTS's output goes on. */
static const char *
output_resume(lane_conn_t *conn)
{
	if (conn->out == NULL)
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
 * The frame ERTS reads: the control term behind a pass-through byte, which overwrites
 * the frame header's last byte once the funnel has judged it, and then the payload.
 */
static void
input_deliver(lane_conn_t *conn, DistEntry *dep, Uint32 conn_id, size_t len, erx_net_answer_t answer)
{
	conn->in[ERX_FRAME_HEADER_SIZE - 1] = PASS_THROUGH;
	erts_atomic64_inc_nob(&dep->in);	/* erlang:dist_get_stat/1's count of frames in */
	(void)erts_net_message(NULL, dep, conn_id, NULL, 0, NULL, conn->in + ERX_FRAME_HEADER_SIZE - 1,
	    len - (ERX_FRAME_HEADER_SIZE - 1), answer);
}

/*
 * An exit whose payload is over a limit arrives with reason {erx_reason_too_large, Bytes},
 * written behind the held control term: the buffer never shrinks below
 * ERX_FUNNEL_ASM_FIRST, which leaves room for it behind the longest one.
 */
static void
input_too_large(lane_conn_t *conn, DistEntry *dep, Uint32 conn_id, const erx_funnel_verdict_t *verdict)
{
	const size_t at = ERX_FRAME_HEADER_SIZE + verdict->header.ctl_len;
	uint8_t reason[TOO_LARGE_REASON_MAX];
	erx_etf_writer_t writer;
	size_t reason_len;

	erx_etf_writer_init(&writer, reason, sizeof(reason));
	erx_etf_put_tuple(&writer, 2);
	erx_etf_put_atom(&writer, "erx_reason_too_large", 20);
	erx_etf_put_integer(&writer, (int64_t)verdict->header.payload_len);
	if (!erx_etf_writer_done(&writer, &reason_len) || conn->in_cap < at + reason_len) {
		count(conn, ERX_LANE_COUNT_DROPPED);
		return;
	}
	memcpy(conn->in + at, reason, reason_len);
	input_deliver(conn, dep, conn_id, at + reason_len, ERX_NET_DELIVER);
	count(conn, ERX_LANE_COUNT_DELIVERED);
}

/* What the verdict table chose for a whole frame, done through the entry's own queue. */
static bool
input_act(lane_conn_t *conn, DistEntry *dep, Uint32 conn_id, const erx_funnel_verdict_t *verdict)
{
	const size_t control = ERX_FRAME_HEADER_SIZE + verdict->header.ctl_len;

	switch (verdict->action) {
	case ERX_FUNNEL_DELIVER:
		input_deliver(conn, dep, conn_id, conn->assembly.frame, ERX_NET_DELIVER);
		count(conn, ERX_LANE_COUNT_DELIVERED);
		return (true);
	case ERX_FUNNEL_DELIVER_IF_LINKED:
		/*
		 * A LINK the peer has no link right for is kept when the target already holds a
		 * link with the sender, as one of this domain's processes makes toward a peer's
		 * process it was sent. That conditional LINK needs the export table's link record
		 * (RT7, TODO.md); without it the LINK is answered as for an absent target, which is
		 * wrong only when such a link exists: the peer's process then gets an exit of noproc.
		 */
	case ERX_FUNNEL_ANSWER_NOPROC:
		input_deliver(conn, dep, conn_id, control, ERX_NET_NOPROC);
		count(conn, ERX_LANE_COUNT_ANSWERED);
		return (true);
	case ERX_FUNNEL_ANSWER_SPAWN:
		input_deliver(conn, dep, conn_id, control, verdict->cause == ERX_FUNNEL_CAUSE_OVER_LIMIT ?
		    ERX_NET_SPAWN_LIMIT : ERX_NET_SPAWN_UNAUTHORISED);
		count(conn, ERX_LANE_COUNT_ANSWERED);
		return (true);
	case ERX_FUNNEL_TOO_LARGE:
		input_too_large(conn, dep, conn_id, verdict);
		return (true);
	case ERX_FUNNEL_DROP:
		count(conn, ERX_LANE_COUNT_DROPPED);
		return (true);
	case ERX_FUNNEL_MALFORMED:
		break;
	}
	return (false);
}

/* Without an export table the peer holds nothing on any name (RT7, TODO.md). */
static erx_funnel_hold_t
exports_none(const void *exports, const erx_funnel_name_t *name)
{
	(void)exports;
	(void)name;
	return ((erx_funnel_hold_t){ 0 });
}

/*
 * The system domain holds what every runtime exports to it before its first frame
 * (docs/design-runtime.md, "Connections in ERTS"): spawn on the domain. init's send, and
 * the same exports to the spawner, wait for the export table (RT7, TODO.md).
 */
static erx_funnel_hold_t
exports_system(const void *exports, const erx_funnel_name_t *name)
{
	(void)exports;
	return ((erx_funnel_hold_t){ .rights = name->kind == ERX_FUNNEL_NAME_DOMAIN ? ERX_RIGHT_SPAWN : 0 });
}

typedef enum {
	STEP_TOOK,		/* a whole record was taken and acted on */
	STEP_EMPTY,		/* nothing more is published, and the wait is */
	STEP_BROKEN,		/* the lane or a frame failed a check: nothing more is delivered */
	STEP_NO_MEMORY,		/* the record's buffer could not grow */
	STEP_ANSWERS_UNREAD	/* an answerable frame came past ERX_LANE_ANSWERS_MAX unsent */
} step_t;

/*
 * Whether a frame of op can make this domain answer the peer with a send that has no
 * sending process: an exit or DOWN noproc, an unlink ack, or a spawn reply. Such sends
 * ignore the busy limit (dist.c, erts_dsig_prepare), so these are the frames bounded.
 */
static bool
op_answered(erx_funnel_op_t op)
{
	return (op == ERX_FUNNEL_LINK || op == ERX_FUNNEL_MONITOR_P || op == ERX_FUNNEL_UNLINK_ID ||
	    op == ERX_FUNNEL_SPAWN_REQUEST);
}

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

/* One funnel step: the rest of the open record, or the next one, judged once whole. */
static step_t
input_step(lane_conn_t *conn, DistEntry *dep, Uint32 conn_id)
{
	erx_funnel_asm_plan_t plan;
	erx_funnel_verdict_t verdict;
	erx_lane_part_t part;
	bool acted;

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
	erx_funnel_check(conn->in, conn->assembly.frame, conn->assembly.held, &conn->lane, &conn->limits,
	    conn->scratch, conn->scratch_len, &verdict);
	if (verdict.action != ERX_FUNNEL_MALFORMED && verdict.action != ERX_FUNNEL_DROP &&
	    op_answered(verdict.control.op) && answers_unsent(dep) >= ERX_LANE_ANSWERS_MAX)
		return (STEP_ANSWERS_UNREAD);
	acted = input_act(conn, dep, conn_id, &verdict);
	erx_funnel_asm_next(&conn->assembly);
	return (acted ? STEP_TOOK : STEP_BROKEN);
}

/*
 * The input task's frames, up to the allowance, whether or not the entry is busy: input
 * never waits on output, so two domains streaming to each other never hold each other's
 * lanes. Before the port controls an entry it takes nothing, and erx_dist runs it again
 * after setnode/3. NULL, or the reason the port must end.
 */
static const char *
input_run(lane_conn_t *conn)
{
	const uint32_t allowance = erx_lane_batch != 0 ? erx_lane_batch : 1;
	DistEntry *dep;
	Uint32 conn_id = 0;

	dep = conn_entry(conn, &conn_id);
	if (dep == NULL)
		return (NULL);
	for (uint32_t steps = 0; steps < allowance; steps++) {
		switch (input_step(conn, dep, conn_id)) {
		case STEP_TOOK:
			break;
		case STEP_EMPTY:
			return (NULL);
		case STEP_BROKEN:
			count(conn, ERX_LANE_COUNT_MALFORMED);
			return ("erx_lane_malformed");
		case STEP_NO_MEMORY:
			return ("erx_lane_no_memory");
		case STEP_ANSWERS_UNREAD:
			return ("erx_lane_answers_unread");
		}
	}
	input_schedule(conn);	/* at its allowance: the next run takes the rest */
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
	driver_free(conn);
}

/* A connection's values, from the open command. */
typedef struct lane_open {
	uint64_t	 side, peer_side, peer_bell;
	uint32_t	 label, out_size, in_size, peer_id;
	const char	*peer_node;
	size_t		 peer_node_len;
	bool		 system;	/* the system connection, from the boot page */
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
 * "erx_lane system", the boot page's system connection and its peer's node name, or
 * "erx_lane Side PeerSide PeerBell Label OutSize InSize PeerId PeerNode". The node name is
 * checked by copy_name's length and by every frame's sender rule, which compares it whole.
 */
static bool
lane_open_parse(const char *command, lane_open_t *open)
{
	static const char system_word[] = "erx_lane system";
	static const char driver_word[] = "erx_lane ";
	const char *at = command;
	uint64_t words[7];

	if (strcmp(at, system_word) == 0) {
		const erx_boot_info_t *const boot = erx_runtime_boot();
		const erx_boot_connection_t *const sys = &boot->system_connection;

		*open = (lane_open_t){ .side = sys->side.raw, .peer_side = sys->peer_side.raw, .peer_bell = sys->peer_bell.raw,
			.label = sys->label, .out_size = sys->out_size, .in_size = sys->in_size, .peer_id = sys->peer,
			.system = true };
		open->peer_node = erx_runtime_system_node(&open->peer_node_len);
	} else {
		if (strncmp(at, driver_word, sizeof(driver_word) - 1) != 0)
			return (false);
		at += sizeof(driver_word) - 1;
		for (size_t i = 0; i < 7; i++)
			if (!open_word(&at, i < 3 ? UINT64_MAX : UINT32_MAX, &words[i]))
				return (false);
		*open = (lane_open_t){ .side = words[0], .peer_side = words[1], .peer_bell = words[2],
			.label = (uint32_t)words[3], .out_size = (uint32_t)words[4], .in_size = (uint32_t)words[5],
			.peer_id = (uint32_t)words[6], .peer_node = at, .peer_node_len = strlen(at) };
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
 * are the boot page's, or "erx_lane Side PeerSide PeerBell Label OutSize InSize
 * PeerId PeerNode" for one connection_up introduced. Maps both sides, prepares the lane's
 * writer and reader, and registers the bell's label as the connection's sink.
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
	conn->own_bytes = erx_lane_side_bytes(open.out_size);
	conn->peer_bytes = erx_lane_side_bytes(open.in_size);
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
		.lookup = open.system ? exports_system : exports_none, .exports = NULL, .sender_id = open.peer_id,
		.receiver_id = (uint32_t)erts_this_node->creation };
	conn->scratch_len = erx_funnel_check_scratch_bytes(&conn->limits);
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

/* The sink goes first, and with it every input task still scheduled. */
static void
lane_stop(ErlDrvData data)
{
	lane_conn_t *const conn = (lane_conn_t *)data;

	erx_event_unregister_connection(conn->label, conn->port);
	conn_free(conn);
}

/*
 * port_control(Port, 0, []): the counts, as 64-bit words. port_control(Port, 1, []): one
 * run of the input task, which erx_dist asks for after setnode/3 makes the port the
 * entry's controller, so frames that arrived before then are taken without a bell.
 */
static ErlDrvSSizeT
lane_control(ErlDrvData data, unsigned int command, char *buf, ErlDrvSizeT len, char **rbuf, ErlDrvSizeT rlen)
{
	lane_conn_t *const conn = (lane_conn_t *)data;
	const ErlDrvSizeT need = ERX_LANE_COUNTS * 8;

	(void)buf;
	(void)len;
	if (command == CONTROL_KICK) {
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
 * erx_dist:boot/0, the boot page's identity for erx_dist's listen/2 and acceptor:
 * {DomainId, {PeerId, PeerNode}} for a domain with a system connection, and {DomainId, none}
 * for the system domain, which has none. Its one atom is the system domain's node name,
 * which the domain library wrote and the boot page's reader checked is <name>@<host>.
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

		if (is_non_value(node))
			BIF_ERROR(BIF_P, SYSTEM_LIMIT);
		hp = HAlloc(BIF_P, 3);
		/* A u32 is a small integer on the 64-bit builds erXos makes. */
		system = TUPLE2(hp, make_small((Uint)sys->peer), node);
	}
	hp = HAlloc(BIF_P, 3);
	BIF_RET(TUPLE2(hp, make_small((Uint)boot->domain_id), system));
}
