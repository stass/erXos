/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

#ifndef ERX_LANE_H
#define ERX_LANE_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

/*
 * Both sides of a lane: its one reader and its one writer.
 *
 * A lane carries records from a producer to a consumer through two memory
 * objects.  The producer's side holds the ring header (its published write
 * position wpos and the read position it waits for, need) and the data
 * area; the consumer maps it read-only.  The consumer's side holds the
 * reader page (its published read position rpos and the write position it
 * waits for, wake); the producer maps it read-only.  Every record is a
 * 16-byte header (len, kind, zero) followed by len body bytes padded to 16.
 *
 * Each party is untrusted by the other and writes its own side
 * concurrently.  So each loads every field of the other's side once per
 * decision, into private memory, with atomic loads, and validates the copy
 * before using it.  Neither reads back its own side: its own position
 * lives in its private record below, and its own side only receives
 * stores.  The first check a lane fails refuses the lane for good.
 *
 * A record is read as it is published, and written as room returns:
 * erx_lane_put writes the header and as much of the body as fits, and the
 * rest on later calls; erx_lane_take returns the header and as much of the
 * body as is published and fits the caller's buffer, and releases the room
 * behind what it copied at once.  So a record may be longer than the lane.
 *
 * The wake handshake: a party with nothing to do publishes the position it
 * waits for in its own side (the consumer wake, in erx_lane_take_armed;
 * the producer need, in erx_lane_put_armed), executes a full fence and
 * looks once more; the other, after each store of its own position,
 * executes a full fence, loads the waited-for position and reports in
 * part->ring or put->ring that its store crossed it, so the caller rings
 * the waiter's bell.  A store that crosses nothing rings nothing.
 */

typedef struct erx_lane_part erx_lane_part_t;
typedef struct erx_lane_reader erx_lane_reader_t;

typedef enum erx_lane_status {
	ERX_LANE_TOOK = 1,	/* a part was taken: a header, body bytes or both */
	ERX_LANE_EMPTY,		/* nothing new is published */
	ERX_LANE_MALFORMED	/* the lane failed a check; see the reader's fault */
} erx_lane_status_t;

/*
 * The check a refused lane failed; ERX_LANE_SOUND while it has failed none.
 * The reader fails the wpos and record checks, the writer the rpos ones.
 */
typedef enum erx_lane_fault {
	ERX_LANE_SOUND = 0,
	ERX_LANE_WPOS_UNALIGNED,	/* wpos is not a multiple of 16 */
	ERX_LANE_WPOS_BEHIND,		/* wpos is below what was already read */
	ERX_LANE_WPOS_AHEAD,		/* wpos is more than the area past rpos */
	ERX_LANE_RECORD_TOO_LONG,		/* a record's len is past ERX_FRAME_MAX */
	ERX_LANE_RECORD_PAST_END,		/* a record would end past the last position */
	ERX_LANE_RPOS_UNALIGNED,	/* rpos is not a multiple of 16 */
	ERX_LANE_RPOS_BEHIND,		/* rpos is below an rpos already read */
	ERX_LANE_RPOS_AHEAD		/* rpos is past what was published */
} erx_lane_fault_t;

/* Where a reader or a writer is: between records, inside one, or refused. */
typedef enum erx_lane_phase {
	ERX_LANE_BETWEEN = 0,	/* the next published byte starts a header */
	ERX_LANE_IN_BODY,	/* body_left bytes of the open record remain */
	ERX_LANE_REFUSED	/* fault names the failed check */
} erx_lane_phase_t;

/*
 * One part of a record.  Every part carries the open record's header as
 * the reader copied it once, so a use checks kind and zero against its own
 * rules; opened says this part read that header, and closed that it took
 * the last body byte.  ring says that the store of rpos this part made
 * crossed the producer's published need: the caller rings the producer's
 * bell.
 */
struct erx_lane_part {
	uint64_t	 offset;	/* body offset of the first byte copied */
	uint64_t	 zero;		/* the header's third word */
	size_t		 copied;	/* bytes copied into the caller's buffer */
	uint32_t	 len;		/* the header's body length */
	uint32_t	 kind;		/* the header's record kind */
	bool		 opened;
	bool		 closed;
	bool		 ring;
};

/*
 * A consumer's private state for one lane.  The caller owns the storage;
 * only erx_lane.c changes the fields, which the caller may read.  pos is
 * exact and may stop inside a 16-byte granule when a caller's buffer does;
 * the rpos the reader publishes is pos rounded down to 16, so the producer
 * never overwrites a granule the reader has not finished.
 */
struct erx_lane_reader {
	const unsigned char	*peer_side;	/* producer's side, read-only */
	unsigned char		*own_side;	/* consumer's side: the reader page */
	uint64_t		 size;		/* data area bytes, a power of two */
	uint64_t		 pos;		/* bytes consumed since creation */
	uint64_t		 body_left;	/* body bytes of the open record */
	uint64_t		 zero;		/* the open record's header ... */
	uint32_t		 len;
	uint32_t		 kind;		/* ... as copied once */
	erx_lane_phase_t	 phase;
	erx_lane_fault_t	 fault;
	bool			 stopped;	/* erx_lane_reader_stop fixed wpos ... */
	uint64_t		 stop_wpos;	/* ... at this checked copy */
};

/*
 * Prepares a reader for a lane that starts empty.  peer_side and own_side
 * are the page-aligned mappings of the producer's side and the consumer's
 * side; size is the data area's size, from the system domain's word and
 * never from a page the producer writes.  Fails, touching nothing, on a
 * NULL or misaligned side or a size that is not a power of two from
 * ERX_LANE_MIN to ERX_LANE_MAX.
 */
bool erx_lane_reader_init(erx_lane_reader_t *, const void *, void *,
    uint64_t);

/*
 * The bytes of one side of a lane whose data area is size bytes: the
 * header and reader pages, then the data area. 0 for a size that is not
 * a power of two from ERX_LANE_MIN to ERX_LANE_MAX. The domain library
 * sizes a connection's sides with it, so no other file names the layout.
 */
uint64_t erx_lane_side_bytes(uint64_t);

/*
 * Fixes the write position the reader takes up to: loads wpos once and
 * checks it as a take does, and every later take reads up to that copy
 * and never loads wpos again, so nothing the producer publishes after it
 * is taken.  A record the copy cuts short stays open (phase
 * ERX_LANE_IN_BODY) once every byte before the copy is taken, and takes
 * then return ERX_LANE_EMPTY.  A wpos that fails its check refuses the
 * lane.  Returns false when the lane is refused, now or before; a second
 * call changes nothing and returns true.
 */
bool erx_lane_reader_stop(erx_lane_reader_t *);

/*
 * Takes the next part of the lane into buf, at most max bytes of body.
 * Returns ERX_LANE_TOOK with *part filled, ERX_LANE_EMPTY when nothing new
 * is published, or ERX_LANE_MALFORMED when the lane fails a check, now or
 * before.  A part with max of 0 reads a header and copies nothing; inside
 * a body, max of 0 takes nothing and returns ERX_LANE_TOOK with copied 0,
 * so a caller whose buffer is full stops taking rather than loops.  A
 * caller that discards a body takes it into a scratch buffer.  When
 * part->ring is set the caller must ring the producer's bell, or a
 * producer waiting for room may wait for good.  buf may be NULL only with
 * max of 0.
 */
erx_lane_status_t erx_lane_take(erx_lane_reader_t *, void *, size_t,
    erx_lane_part_t *);

/*
 * As erx_lane_take, after publishing in the reader page that the consumer
 * waits for the next byte: wake is the published rpos plus one.  ERX_LANE_EMPTY from it means the producer will
 * ring the consumer's bell when it publishes that byte, so the caller may
 * park on its group; a stopped reader takes nothing past its stop, so no
 * ring is owed to it.  A caller that is not about to park uses
 * erx_lane_take, so a busy lane costs the producer no ring.
 */
erx_lane_status_t erx_lane_take_armed(erx_lane_reader_t *, void *, size_t,
    erx_lane_part_t *);

/* ----------------------------------------------------------------- writer */

typedef struct erx_lane_iov erx_lane_iov_t;
typedef struct erx_lane_item erx_lane_item_t;
typedef struct erx_lane_put erx_lane_put_t;
typedef struct erx_lane_writer erx_lane_writer_t;

typedef enum erx_lane_put_status {
	ERX_LANE_PUT_DONE = 1,	/* the record's last byte is written */
	ERX_LANE_PUT_SHORT,	/* room ran out first; put again for the rest */
	ERX_LANE_PUT_REFUSED,	/* the item cannot be written; nothing was */
	ERX_LANE_PUT_MALFORMED	/* the lane failed a check; see the writer's fault */
} erx_lane_put_status_t;

/* One piece of a record's body. */
struct erx_lane_iov {
	const void	*base;
	size_t		 len;
};

/*
 * One record to put: its header's kind and zero word, its body as the
 * concatenation of iovcnt pieces, and the room it must leave free behind
 * it.  reserve is 0 but for an ordinary record in a lane that holds a
 * reserve for control records (the system domain's lane to a domain),
 * which never takes that room; a control record there puts with 0.  whole
 * asks for the record in one put: a put writes none of it until the room
 * past the reserve holds all of it, an armed put waits for that room, and
 * a record larger than the area past the reserve, or put while another
 * record is open, is refused, so a writer
 * whose lane several threads share writes each record whole under its
 * lock and never pauses inside one.  The caller passes the same item to
 * every call that writes one record, and keeps the pieces and their array
 * private while a call runs.
 */
struct erx_lane_item {
	const erx_lane_iov_t	*iov;
	size_t			 iovcnt;
	uint64_t		 zero;
	uint64_t		 reserve;
	uint32_t		 kind;
	bool			 whole;
};

/*
 * What one call wrote of a record: written body bytes from body offset
 * offset; opened says it wrote the header, closed that it wrote the body's
 * last byte.  ring says that a store of wpos this call made crossed the
 * consumer's published wake: the caller rings the consumer's bell.
 */
struct erx_lane_put {
	uint64_t	 offset;
	size_t		 written;
	bool		 opened;
	bool		 closed;
	bool		 ring;
};

/*
 * A producer's private state for one lane.  The caller owns the storage;
 * only erx_lane.c changes the fields, which the caller may read.  pos is
 * the wpos last published, a multiple of 16; rpos is the consumer's last
 * rpos that passed the checks, below which the producer never writes again
 * and above which it never writes what is unread.
 */
struct erx_lane_writer {
	unsigned char		*own_side;	/* producer's side: header, area */
	const unsigned char	*peer_side;	/* consumer's side, read-only */
	uint64_t		 size;		/* data area bytes, a power of two */
	uint64_t		 pos;		/* bytes published since creation */
	uint64_t		 rpos;		/* the consumer's rpos, validated */
	uint64_t		 body_left;	/* body bytes of the open record */
	uint64_t		 zero;		/* the open record's header ... */
	uint32_t		 len;
	uint32_t		 kind;		/* ... as written */
	erx_lane_phase_t	 phase;
	erx_lane_fault_t	 fault;
};

/*
 * Prepares a writer for a lane that starts empty.  own_side and peer_side
 * are the page-aligned mappings of the producer's side and the consumer's
 * side; size is the data area's size, from the system domain's word and
 * never from a page the consumer writes.  Fails, touching nothing, as
 * erx_lane_reader_init does.
 */
bool erx_lane_writer_init(erx_lane_writer_t *, void *, const void *,
    uint64_t);

/*
 * Writes what fits of the item's record: the header, when the record is
 * not open yet and the room past the reserve holds it, then as much of the
 * body as that room holds, then publishes it all with one store of wpos.
 * Returns ERX_LANE_PUT_DONE when the record's last byte is written,
 * ERX_LANE_PUT_SHORT when room ran out first (put->written may be 0),
 * ERX_LANE_PUT_REFUSED, writing nothing, for a missing piece, a body past
 * ERX_FRAME_MAX, a whole record larger than the area past the reserve or
 * put while another record is open, an item other than the open record's
 * (another length, kind or zero word), a reserve that leaves no room for a
 * header, or a record that would end past the last position,
 * and ERX_LANE_PUT_MALFORMED when the consumer's rpos fails a check, now or
 * before.  When put->ring is set the caller must ring the consumer's bell,
 * or a consumer waiting for the record may wait for good.
 */
erx_lane_put_status_t erx_lane_put(erx_lane_writer_t *,
    const erx_lane_item_t *, erx_lane_put_t *);

/*
 * As erx_lane_put, after publishing in the ring header the rpos at which
 * the room past the reserve holds the rest of the record or a quarter of
 * the lane, whichever is less, or the whole record for an item marked
 * whole.  It puts again, re-publishing need, until
 * a put writes nothing or the record is done, and *put sums what it
 * wrote.  ERX_LANE_PUT_SHORT from it means the consumer will ring the
 * producer's bell when that room returns, so the caller may pause.  A
 * caller that is not about to pause uses erx_lane_put, so a lane with
 * room costs the consumer no ring.
 */
erx_lane_put_status_t erx_lane_put_armed(erx_lane_writer_t *,
    const erx_lane_item_t *, erx_lane_put_t *);

/*
 * The control table (docs/design-domains.md, "The control table"): slots
 * fixed slots after the data area of the system domain's side of a
 * domain's system connection, each holding at most one frame of
 * ERX_LANE_CTL_SLOT bytes.  The system domain writes a slot with
 * erx_lane_ctl_put, the table's one writer; the domain reads it with
 * erx_lane_ctl_take, its one reader.  Each keeps its own copy of every
 * slot's seq, the writer the one it stored last and the reader the one it
 * took last, so neither reads back what it wrote.
 */
typedef enum erx_lane_ctl_status {
	ERX_LANE_CTL_UNCHANGED,	/* seq is the reader's copy: nothing to take */
	ERX_LANE_CTL_TOOK,	/* seq is one past the copy: the record taken */
	ERX_LANE_CTL_REWRITTEN,	/* seq moved by anything but one: the
				 * newest record taken, and the slot was
				 * rewritten before its record was answered */
	ERX_LANE_CTL_MALFORMED	/* a len or zero out of range, or a bad call */
} erx_lane_ctl_status_t;

/*
 * The bytes of a side whose data area is size bytes followed by a control
 * table of slots slots, rounded up to a page; erx_lane_side_bytes(size)
 * rounded up for 0 slots.  0 for a size that is not a lane's.
 */
uint64_t erx_lane_ctl_side_bytes(uint64_t, uint32_t);

/*
 * Writes slot slot of the table on side, whose data area is size bytes
 * and whose table has slots slots: the frame header, ctl_len bytes of ctl
 * and payload_len bytes of payload, zeros to the slot's end, then len,
 * and last seq with release order.  seq is the writer's own count of the
 * records written into the slot, plus one.  The caller rings the domain's
 * bell after it.  false, writing nothing, for a misaligned side, a size
 * that is not a lane's, a slot past the table or a frame longer than
 * ERX_LANE_CTL_SLOT.
 */
bool erx_lane_ctl_put(void *, uint64_t, uint32_t, uint32_t, uint64_t,
    const void *, size_t, const void *, size_t);

/*
 * Looks at slot slot of the table on side, against kept, the seq the
 * caller took from it last.  Unless seq is unchanged, copies len and zero
 * once, checks len from ERX_FRAME_HEADER_SIZE to ERX_LANE_CTL_SLOT and zero
 * zero, and copies the frame once into buf, which holds ERX_LANE_CTL_SLOT
 * bytes; *len is the frame's length and *seq the seq it was read under,
 * which the caller keeps once it has delivered the frame.
 */
erx_lane_ctl_status_t erx_lane_ctl_take(const void *, uint64_t, uint32_t,
    uint32_t, uint64_t, void *, uint32_t *, uint64_t *);

#endif /* ERX_LANE_H */
