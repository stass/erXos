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
 * The consumer's side of a lane: the one reader of a lane's ring.
 *
 * A lane carries records from a producer to a consumer through two memory
 * objects.  The producer's side holds the ring header (its published write
 * position wpos and the read position it waits for, need) and the data
 * area; the consumer maps it read-only.  The consumer's side holds the
 * reader page (its published read position rpos and the write position it
 * waits for, wake); the producer maps it read-only.  Every record is a
 * 16-byte header (len, kind, zero) followed by len body bytes padded to 16.
 *
 * The producer is untrusted and writes its side concurrently.  The reader
 * therefore loads every field of the producer's side once per decision,
 * into private memory, with atomic loads, and validates the copy before
 * using it.  It never reads back the reader page: its own position lives
 * in the reader record below, and the reader page only receives stores.
 * The first check a lane fails refuses the lane for good.
 *
 * A record is read as it is published: erx_lane_take returns the header
 * and as much of the body as is published and fits the caller's buffer,
 * and releases the room behind what it copied at once, so a record may be
 * longer than the lane itself.
 */

typedef struct erx_lane_part erx_lane_part_t;
typedef struct erx_lane_reader erx_lane_reader_t;

typedef enum erx_lane_status {
	ERX_LANE_TOOK = 1,	/* a part was taken: a header, body bytes or both */
	ERX_LANE_EMPTY,		/* nothing new is published */
	ERX_LANE_MALFORMED	/* the lane failed a check; see the reader's fault */
} erx_lane_status_t;

/* The check a refused lane failed; ERX_LANE_SOUND while it has failed none. */
typedef enum erx_lane_fault {
	ERX_LANE_SOUND = 0,
	ERX_LANE_WPOS_UNALIGNED,	/* wpos is not a multiple of 16 */
	ERX_LANE_WPOS_BEHIND,		/* wpos is below what was already read */
	ERX_LANE_WPOS_AHEAD,		/* wpos is more than the area past rpos */
	ERX_LANE_RECORD_TOO_LONG,		/* a record's len is past ERX_FRAME_MAX */
	ERX_LANE_RECORD_PAST_END		/* a record would end past the last position */
} erx_lane_fault_t;

/* Where the reader is: between records, inside one, or refused. */
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
 * park on its group.  A caller that is not about to park uses
 * erx_lane_take, so a busy lane costs the producer no ring.
 */
erx_lane_status_t erx_lane_take_armed(erx_lane_reader_t *, void *, size_t,
    erx_lane_part_t *);

#endif /* ERX_LANE_H */
