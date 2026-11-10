/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

#ifndef ERX_FUNNEL_H
#define ERX_FUNNEL_H

/*
 * erx_funnel's grammar: the pure checks that judge the shape and size of a
 * frame from another domain before anything acts on it
 * (docs/design-domains.md, "The funnel").  Three functions, in the order
 * the funnel applies them to one lane record:
 *
 * erx_funnel_header checks the frame's 8-byte header against the record's
 * length: the control term is 2 to ERX_CTL_MAX bytes and the two terms
 * fill the frame exactly.
 *
 * erx_funnel_control judges the control term: erx_etf accepts it in the
 * system grammar (no funs or exports) with the semantic stage, and it is
 * the control tuple of one of
 * the operations of design-domains.md's "Frames", with that operation's
 * arity and the kind of every element.  It returns the operation and the
 * pids, references and values the tuple names, pointing into the input, so
 * the sender rule, the target rule and the export lookups judge them.
 * Which pid belongs to whom is not decided here: every pid and reference
 * is only required to be well formed with a node name at the machine's
 * host.  A control term it refuses is malformed: its limits are the
 * grammar's own, which every correct runtime keeps, erXos's peer
 * checking a spawn request's options before it writes one.
 *
 * erx_funnel_payload is the payload's structural pass: erx_etf_check with
 * accept off, in the grammar the receiving domain chooses, holding the
 * decoded size in heap words, which erx_etf counts exactly as ERTS's size
 * pass does, to the receiver's word limit and the nesting to its
 * funnel_depth.  Its verdict is erx_etf's: malformed, over a limit, or
 * accepted with the term's decoded words.  The semantic stage (map keys
 * equal under =:=) is the receiving decoder's.
 *
 * erx_funnel_check is the funnel's whole judgment of one copied frame, and
 * the one function a runtime's drain calls: it applies the three checks
 * above, the sender rule and the target rule, asks the receiver's export
 * table for the one right the operation needs, and returns the verdict
 * table's action for the frame (design-domains.md, "The funnel", steps 2
 * to 7).
 *
 * All four are pure: they read only their arguments, and the export
 * table only through the lookup the caller passes, and write only their
 * results and the caller's scratch.  None recurses.
 */

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#include "erx/abi.h"
#include "erx/etf.h"

struct erx_lane_part;

typedef struct erx_funnel_control erx_funnel_control_t;
typedef struct erx_funnel_header erx_funnel_header_t;

/* The operations of the grammar, by OTP's distribution operation number. */
typedef enum erx_funnel_op {
	ERX_FUNNEL_LINK = 1,
	ERX_FUNNEL_GROUP_LEADER = 7,
	ERX_FUNNEL_MONITOR_P = 19,
	ERX_FUNNEL_DEMONITOR_P = 20,
	ERX_FUNNEL_SEND_SENDER = 22,
	ERX_FUNNEL_PAYLOAD_EXIT = 24,
	ERX_FUNNEL_PAYLOAD_EXIT2 = 26,
	ERX_FUNNEL_PAYLOAD_MONITOR_P_EXIT = 28,
	ERX_FUNNEL_SPAWN_REQUEST = 29,
	ERX_FUNNEL_SPAWN_REPLY = 31,
	ERX_FUNNEL_ALIAS_SEND = 33,
	ERX_FUNNEL_UNLINK_ID = 35,
	ERX_FUNNEL_UNLINK_ID_ACK = 36,
} erx_funnel_op_t;

/* Why a frame's header or control term was refused. */
typedef enum erx_funnel_reason {
	ERX_FUNNEL_OK,
	ERX_FUNNEL_ERR_HEADER,	/* a frame shorter than its header, or terms
				   that do not fill it exactly */
	ERX_FUNNEL_ERR_CTL_LEN,	/* a control term under 2 bytes or past
				   ERX_CTL_MAX */
	ERX_FUNNEL_ERR_TERM,	/* erx_etf refused the control term */
	ERX_FUNNEL_ERR_OP,	/* not a tuple led by an operation of the
				   grammar */
	ERX_FUNNEL_ERR_ARITY,	/* the operation's tuple has another arity */
	ERX_FUNNEL_ERR_FIELD,	/* an element of the wrong kind or range */
	ERX_FUNNEL_ERR_OPTION,	/* a spawn option list that is not a proper
				   list of options */
	ERX_FUNNEL_ERR_PAYLOAD,	/* a payload for an operation without one,
				   or none for an operation with one */
	ERX_FUNNEL_ERR_SENDER,	/* a pid or reference of the sender's own
				   without the lane's node name and domain
				   id */
	ERX_FUNNEL_ERR_TARGET,	/* a target without the receiver's node
				   name, or one of the receiver's own past
				   ERTS's internal range */
	ERX_FUNNEL_ERR_VERSION,	/* a payload whose first byte is not the
				   version byte 131 */
	ERX_FUNNEL_ERR_PAYLOAD_TERM, /* erx_etf refused an authorised
				   payload as malformed */
	ERX_FUNNEL_ERR_HELD,	/* the caller held less of a discarded frame
				   than its header, control term and the
				   payload's first byte */
	ERX_FUNNEL_ERR_VERDICT,	/* the verdict table has no action for the
				   operation and cause, which no frame
				   reaches */
} erx_funnel_reason_t;

/* A frame's two terms: control first, then payload (absent when 0). */
struct erx_funnel_header {
	uint32_t		 ctl_len;
	uint32_t		 payload_len;
};

/*
 * The members of erx_funnel_control_t an operation sets, as
 * ERX_FUNNEL_HAS_* bits in its fields; every other member is zero.  Each
 * member has one owner whatever the operation: from and sender_ref are
 * the sender's own, so the sender rule judges them; to and receiver_ref
 * are the receiver's, so the target rule judges them; group_leader is
 * data, as a pid in a payload is.
 *
 *   operation (number)        control tuple                 sets
 *   LINK (1)                  {1, FromPid, ToPid}           from to
 *   GROUP_LEADER (7)          {7, FromPid, ToPid}           from to
 *   MONITOR_P (19)            {19, FromPid, ToProc, Ref}    from to sender_ref
 *   DEMONITOR_P (20)          {20, FromPid, ToProc, Ref}    from to sender_ref
 *   SEND_SENDER (22)          {22, FromPid, ToPid}          from to
 *   PAYLOAD_EXIT (24)         {24, FromPid, ToPid}          from to
 *   PAYLOAD_EXIT2 (26)        {26, FromPid, ToPid}          from to
 *   PAYLOAD_MONITOR_P_EXIT    {28, FromProc, ToPid, Ref}    from to receiver_ref
 *   SPAWN_REQUEST (29)        {29, ReqId, From,             sender_ref from
 *                              GroupLeader, {Module,        group_leader spawn
 *                              Function, Arity}, OptList}
 *   SPAWN_REPLY (31)          {31, ReqId, To, Flags,        receiver_ref to spawn,
 *                              Result}                      and from when Result
 *                                                           is a pid
 *   ALIAS_SEND (33)           {33, FromPid, Alias}          from receiver_ref
 *   UNLINK_ID (35)            {35, Id, FromPid, ToPid}      from to id
 *   UNLINK_ID_ACK (36)        {36, Id, FromPid, ToPid}      from to id
 *
 * ToProc and FromProc are pids: a monitor of a registered name is outside
 * the grammar.  ReqId, Ref and Alias are references.  Id is an integer
 * from 1 to 2^64 - 1, as ERTS reads an unlink's (it also takes 0 in an
 * acknowledgement, which repeats a nonzero id).  Module and Function are
 * atoms and Arity an integer of ERTS's small range, which is all ERTS
 * checks before its spawn code judges them.  OptList is a proper list
 * whose elements are atoms or pairs {Atom, Value}, Value an atom, an
 * integer or a map from atoms to atoms and integers.  That is the shape
 * of every option ERTS's spawn takes from the wire, where the sender has
 * already removed link, monitor, reply and reply_tag; so an option list
 * names no pid, reference or fun, and ERTS answers a well-shaped option
 * it does not know with badopt.  Stock ERTS's sender passes other
 * options through; erXos's peer answers them locally with badopt, and a
 * control term past ERX_CTL_MAX with system_limit, so no correct runtime
 * writes them (design-domains.md, "The funnel", step 4).  Flags is an
 * integer below 2^27 and Result a pid (the child) or an atom (the error),
 * as ERTS reads them.  An operation carries a payload exactly when its
 * name says so (SEND_SENDER's message, ALIAS_SEND's message, the exits'
 * reasons, SPAWN_REQUEST's argument list).
 */
#define ERX_FUNNEL_HAS_FROM		0x01u
#define ERX_FUNNEL_HAS_TO		0x02u
#define ERX_FUNNEL_HAS_SENDER_REF	0x04u
#define ERX_FUNNEL_HAS_GROUP_LEADER	0x08u
#define ERX_FUNNEL_HAS_ID		0x10u
#define ERX_FUNNEL_HAS_SPAWN		0x20u
#define ERX_FUNNEL_HAS_RECEIVER_REF	0x40u

/*
 * The depth of the deepest control term of the grammar, in erx_etf frames:
 * an option's map inside SPAWN_REQUEST's option list, or its MFA tuple.
 */
#define ERX_FUNNEL_CTL_DEPTH	2

struct erx_funnel_control {
	erx_etf_pid_t		 from;
	erx_etf_pid_t		 to;
	erx_etf_pid_t		 group_leader;
	erx_etf_ref_t		 sender_ref;
	erx_etf_ref_t		 receiver_ref;
	uint64_t		 id;
	struct {
		const uint8_t	*module;	/* SPAWN_REQUEST's MFA */
		size_t		 module_len;
		const uint8_t	*function;
		size_t		 function_len;
		int64_t		 arity;
		const uint8_t	*error;		/* SPAWN_REPLY's error atom */
		size_t		 error_len;
		uint32_t	 flags;		/* SPAWN_REPLY's Flags */
	} spawn;
	erx_funnel_op_t		 op;
	uint32_t		 fields;	/* ERX_FUNNEL_HAS_* */
	bool			 payload;	/* the operation carries one */
};

/*
 * Checks a frame of frame_len bytes (the record's len) whose first
 * ERX_FRAME_HEADER_SIZE bytes are header, and returns its term lengths.
 */
erx_funnel_reason_t erx_funnel_header(const uint8_t *header,
    uint32_t frame_len, erx_funnel_header_t *result);

/*
 * Judges len bytes of control term, of a frame whose payload is
 * payload_len bytes.  host names the machine, as in erx_etf_rules_t.  The
 * control term also gets erx_etf's semantic stage, which refuses two map
 * keys equal under =:=, so an accepted one is a term ERTS's distribution
 * input decodes to the same value, but for the receiver's own pids and
 * references: ERTS refuses its own pid past its internal id range,
 * which the target rule judges, and takes its own references by edit 17
 * of design-runtime.md.  scratch holds erx_etf's stack and its
 * map-key records: ERX_FUNNEL_CTL_SCRATCH bytes suffice for any control
 * term, since a map keeps at most 32 bytes a pair, a pair takes at least
 * 2 bytes, and a record 4 bytes a field of at least 2 bytes.  On
 * ERX_FUNNEL_ERR_TERM, etf->reason says why erx_etf refused it; otherwise
 * it is ERX_ETF_OK, and only etf->reason is meaningful.  *control is filled only when the term is
 * accepted.
 */
#define ERX_FUNNEL_CTL_SCRATCH	(16u * ERX_CTL_MAX + 1024u)
erx_funnel_reason_t erx_funnel_control(const uint8_t *term, size_t len,
    uint32_t payload_len, const char *host, size_t host_len, void *scratch,
    size_t scratch_len, erx_funnel_control_t *control,
    erx_etf_result_t *etf);

/*
 * The receiver's limits on a payload: the machine's host, its word limit
 * (max_message_heap, or a facet's lower request limit), its funnel_depth,
 * and whether it is the system domain, whose payloads are in the system
 * grammar; every other domain's are in the domain grammar.
 */
typedef struct erx_funnel_limits {
	const char		*host;
	size_t			 host_len;
	uint64_t		 max_words;
	uint32_t		 depth;
	bool			 system;
} erx_funnel_limits_t;

/*
 * The payload's structural pass.  scratch is the connection's funnel
 * state: erx_funnel_payload_scratch_bytes(limits, len) bytes always
 * suffice.
 */
erx_etf_verdict_t erx_funnel_payload(const uint8_t *term, size_t len,
    const erx_funnel_limits_t *limits, void *scratch, size_t scratch_len,
    erx_etf_result_t *result);
size_t erx_funnel_payload_scratch_bytes(const erx_funnel_limits_t *limits,
    size_t len);

/*
 * A name of the receiving domain the export table is asked about: the
 * target pid of an operation on a process, the alias of an alias send, or
 * the domain's own name for a spawn request.
 */
typedef enum erx_funnel_name_kind {
	ERX_FUNNEL_NAME_PID,
	ERX_FUNNEL_NAME_ALIAS,
	ERX_FUNNEL_NAME_DOMAIN,
} erx_funnel_name_kind_t;

typedef struct erx_funnel_name {
	erx_funnel_name_kind_t	 kind;
	const erx_etf_pid_t	*pid;		/* ERX_FUNNEL_NAME_PID */
	const erx_etf_ref_t	*alias;		/* ERX_FUNNEL_NAME_ALIAS */
} erx_funnel_name_t;

/*
 * What the lane's peer holds on a name: its ERX_RIGHT_* bits, none when
 * it was never given the name or the name has no live record, and the
 * named process's request limit in heap words when a facet gave it one
 * (0 when it has none), which lowers a message's word limit.
 */
typedef struct erx_funnel_hold {
	uint64_t		 request_words;
	uint8_t			 rights;
} erx_funnel_hold_t;

/*
 * The receiver's export table, asked one question for the lane's
 * connection: what its peer holds on name. The runtime answers it from
 * the record it already looks up to deliver to the name (design-domains.md,
 * "Exports"), reading only its own memory; it must not change anything the
 * funnel can see.
 */
typedef erx_funnel_hold_t erx_funnel_lookup_fn(const void *connection,
    const erx_funnel_name_t *name);

/*
 * The lane a frame arrived on: the sender's node name and domain id, which
 * the sender rule holds the frame to, the receiver's, which the target
 * rule holds it to, and the receiver's export table toward the sender.
 * The peer's identity is the lane's, never a field of the frame.
 */
typedef struct erx_funnel_lane {
	const char		*sender_node;
	size_t			 sender_node_len;
	const char		*receiver_node;
	size_t			 receiver_node_len;
	erx_funnel_lookup_fn	*lookup;
	const void		*connection;	/* the runtime's, for lookup */
	uint32_t		 sender_id;
	uint32_t		 receiver_id;
} erx_funnel_lane_t;

/* What the runtime does with a frame. */
typedef enum erx_funnel_action {
	ERX_FUNNEL_MALFORMED,		/* end the connection; zero, so a
					   missing table entry fails
					   closed */
	ERX_FUNNEL_DELIVER,		/* hand the control term and the
					   payload to the runtime's
					   distribution input */
	ERX_FUNNEL_DELIVER_IF_LINKED,	/* a LINK without the link right:
					   the target process keeps it when
					   it already holds a link with the
					   sender, in any state, and creates
					   nothing; otherwise it answers it
					   as ERX_FUNNEL_ANSWER_NOPROC.  The
					   target decides when it handles the
					   signal, in order with the sender's
					   earlier ones */
	ERX_FUNNEL_DROP,		/* drop and count it */
	ERX_FUNNEL_ANSWER_NOPROC,	/* answer a LINK with an exit, a
					   MONITOR_P with a DOWN, of reason
					   noproc, on the lane's reverse */
	ERX_FUNNEL_ANSWER_SPAWN,	/* answer the SPAWN_REQUEST with a
					   SPAWN_REPLY of noconnection when
					   unauthorised, system_limit when
					   over a limit */
	ERX_FUNNEL_TOO_LARGE,		/* deliver the exit with reason
					   {erx_reason_too_large, Bytes},
					   Bytes the payload's length */
} erx_funnel_action_t;

/* Which column of the verdict table chose the action. */
typedef enum erx_funnel_cause {
	ERX_FUNNEL_CAUSE_ACCEPTED,	/* authorised and within the limits */
	ERX_FUNNEL_CAUSE_UNAUTHORISED,	/* the peer lacks the right */
	ERX_FUNNEL_CAUSE_DEAD,		/* the target names a process, alias
					   or reference of an ended domain of
					   the receiver's name */
	ERX_FUNNEL_CAUSE_OVER_LIMIT,	/* authorised, and its payload is
					   past a limit or was discarded */
	ERX_FUNNEL_CAUSE_MALFORMED,
} erx_funnel_cause_t;

typedef struct erx_funnel_verdict {
	erx_funnel_action_t	 action;
	erx_funnel_cause_t	 cause;
	erx_funnel_reason_t	 reason;	/* ERX_FUNNEL_OK unless
						   malformed */
	erx_etf_result_t	 etf;		/* erx_etf's result on the
						   control term when it refused
						   it, else on the payload once
						   measured: an accepted
						   payload's words */
	erx_funnel_header_t	 header;	/* once the header passed */
	erx_funnel_control_t	 control;	/* once the control term
						   passed */
} erx_funnel_verdict_t;

/*
 * Judges one frame of frame_len bytes (the record's len), of which the
 * caller copied the first held bytes into frame.  held is frame_len for a
 * whole frame.  The caller puts a frame in discard mode when its payload
 * is past max_frame or the caller could not grow its buffer.  Such a frame
 * holds less: its header, its control term and at least the payload's
 * first byte, and it is over a limit once authorised.  The steps, numbered
 * as design-domains.md's, each able to end the judgment:
 *
 *   2. the header and the payload's version byte: malformed on refusal;
 *   4. the control term (erx_funnel_control), malformed on refusal; the
 *      sender rule: from and sender_ref carry the lane's sender node and
 *      id, else malformed; the target rule: to and receiver_ref carry the
 *      receiver's node, else malformed, and one of another creation names
 *      an ended domain's process, so the frame is dead; a pid of the
 *      receiver's creation has a number below 2^28, ERTS's internal
 *      range, else malformed, since ERTS refuses its own pid past it;
 *   5. authority: the operation's right, looked up once, on its target;
 *      an operation that needs none is always authorised;
 *   3 and 6. the payload, of an authorised frame only: discarded, or past
 *      the limits (a message's word limit lowered to its target's request
 *      limit), is over a limit; one erx_etf refuses is malformed.
 *
 * The action is the verdict table's for the operation and the cause, in
 * erx_funnel.c.  scratch holds at least ERX_FUNNEL_CTL_SCRATCH bytes, so
 * every control term is judged whole; erx_funnel_check_scratch_bytes(limits,
 * held) bytes, which grow with held, suffice for the payload too.  With
 * fewer, a payload that needs more is over a limit, as one past
 * limits->max_words is.  Pointers in verdict->control point into frame.
 */
void erx_funnel_check(const uint8_t *frame, uint32_t frame_len, size_t held,
    const erx_funnel_lane_t *lane, const erx_funnel_limits_t *limits,
    void *scratch, size_t scratch_len, erx_funnel_verdict_t *verdict);
size_t erx_funnel_check_scratch_bytes(const erx_funnel_limits_t *limits,
    size_t held);

/*
 * A frame's assembly from the parts erx_lane_take returns, a pure state
 * machine over a buffer the caller owns.  Before each take the caller asks
 * erx_funnel_asm_plan where the take's bytes go; after it, it reports the
 * part to erx_funnel_asm_took, which says when the record is whole.  The
 * buffer starts at ERX_FUNNEL_ASM_FIRST bytes or more and grows only when
 * the plan asks, never past the record, so a record's length word alone
 * never makes the caller allocate.
 *
 * Once a record's 8-byte frame header is held, the assembly decides from
 * it whether the record is kept whole: one whose header erx_funnel_header
 * refuses, or whose payload is past max_frame, is held only to its first
 * ERX_FUNNEL_ASM_KEEP bytes (its header, the longest control term and the
 * payload's first byte), and the rest is skipped as it arrives; so is the
 * rest of a record whose buffer could not grow.  erx_funnel_check judges
 * such a frame from what it holds, as malformed or over a limit.
 */
#define ERX_FUNNEL_ASM_KEEP	(ERX_FRAME_HEADER_SIZE + ERX_CTL_MAX + 1u)
/* The first buffer: what is kept of any record, and room for an exit
 * reason the runtime writes after a held control term. */
#define ERX_FUNNEL_ASM_FIRST	(ERX_FUNNEL_ASM_KEEP + 63u)

typedef struct erx_funnel_asm {
	uint32_t	 max_frame;	/* the receiver's limit on a payload */
	uint32_t	 frame;		/* the open record's length, 0 between
					   records */
	uint32_t	 held;		/* its bytes in the buffer, from 0 */
	uint32_t	 hold;		/* its bytes the buffer keeps */
	bool		 sized;		/* the header was read */
	bool		 discard;	/* it is kept only in part */
} erx_funnel_asm_t;

typedef enum erx_funnel_asm_where {
	ERX_FUNNEL_ASM_COPY,	/* take at most room bytes into buf + at */
	ERX_FUNNEL_ASM_GROW,	/* grow the buffer to want bytes, or call
				   erx_funnel_asm_ungrown, and plan again */
	ERX_FUNNEL_ASM_SKIP	/* take into a scratch buffer: dropped */
} erx_funnel_asm_where_t;

typedef struct erx_funnel_asm_plan {
	erx_funnel_asm_where_t	 where;
	uint32_t		 at;	/* COPY: the buffer offset */
	uint32_t		 room;	/* COPY: at most this many bytes, >= 1 */
	uint32_t		 want;	/* GROW: the buffer's new size */
} erx_funnel_asm_plan_t;

typedef enum erx_funnel_asm_status {
	ERX_FUNNEL_ASM_MORE = 1,	/* the record is still open */
	ERX_FUNNEL_ASM_WHOLE,		/* judge the buffer's first held bytes
					   as a frame of frame bytes, then
					   erx_funnel_asm_next */
	ERX_FUNNEL_ASM_MALFORMED	/* not a frame record: end the lane */
} erx_funnel_asm_status_t;

/* Between records, for a receiver whose payloads are at most max_frame. */
void erx_funnel_asm_init(erx_funnel_asm_t *, uint32_t max_frame);
/* Where the next take goes, for a buffer of cap bytes. */
void erx_funnel_asm_plan(const erx_funnel_asm_t *, size_t cap,
    erx_funnel_asm_plan_t *);
/* The buffer could not grow: the rest of the record is skipped. */
void erx_funnel_asm_ungrown(erx_funnel_asm_t *);
/*
 * Accounts for a take that returned ERX_LANE_TOOK with part, made where
 * plan said; buf is the buffer, whose first held bytes it reads once the
 * header has arrived.
 */
erx_funnel_asm_status_t erx_funnel_asm_took(erx_funnel_asm_t *,
    const erx_funnel_asm_plan_t *, const struct erx_lane_part *,
    const uint8_t *buf);
/* Closes a whole record, so the next take opens the next one. */
void erx_funnel_asm_next(erx_funnel_asm_t *);

#endif /* !ERX_FUNNEL_H */
