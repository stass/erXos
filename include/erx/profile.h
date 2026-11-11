/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

#ifndef ERX_PROFILE_H
#define ERX_PROFILE_H

/*
 * erx_profile: the one interpreter of a frame profile's table
 * (docs/design-abi.md, "Program protocol").  The ABI generator emits a
 * table for each protocol with "reader c" and typed functions over it
 * (erx/prog_profile.h for erx_prog); this file is what they call.
 *
 * erx_profile_check judges a whole frame, the version byte first, against
 * one frame of the table and accepts it or names one refusal.  It walks
 * the frame once with erx_etf_next and never recurses: its stack is a
 * fixed array of ERX_PROFILE_DEPTH_MAX levels, one per container of the
 * profile, and a LIST_EXT of no element is read as its tail without a
 * level.  On acceptance it fills the frame's struct: every scalar is read
 * into it, every list stays a view (an erx_profile_list_t) whose
 * erx_profile_next reads one element at a time.  Texts and views point
 * into the frame, which the caller keeps unchanged while it uses them.
 * The check is pure: it reads only its arguments and writes only the
 * scratch, the struct and the refusal.
 */

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#define ERX_PROFILE_DEPTH_MAX	16
#define ERX_PROFILE_TOTALS_MAX	8
#define ERX_PROFILE_NONE	UINT16_MAX

typedef struct erx_profile erx_profile_t;
typedef struct erx_profile_case erx_profile_case_t;
typedef struct erx_profile_field erx_profile_field_t;
typedef struct erx_profile_frame erx_profile_frame_t;
typedef struct erx_profile_kind erx_profile_kind_t;
typedef struct erx_profile_list erx_profile_list_t;
typedef struct erx_profile_refers erx_profile_refers_t;
typedef struct erx_profile_refusal erx_profile_refusal_t;
typedef struct erx_profile_signal erx_profile_signal_t;
typedef struct erx_profile_text erx_profile_text_t;
typedef struct erx_profile_total erx_profile_total_t;

/* Why a frame was refused, the names the Erlang grammar gives too. */
typedef enum erx_profile_reason {
	ERX_PROFILE_OK,
	ERX_PROFILE_SIZE,	/* the frame is over its bound */
	ERX_PROFILE_SHAPE,	/* a term of another type or arity, or tag */
	ERX_PROFILE_VERSION,
	ERX_PROFILE_RANGE,
	ERX_PROFILE_LENGTH,	/* a text or a list past its maximum */
	ERX_PROFILE_UTF8,
	ERX_PROFILE_TEXT,	/* a zero byte, an assign or a path rule */
	ERX_PROFILE_KEY,	/* a map key missing or unknown */
	ERX_PROFILE_NO_CASE,
	ERX_PROFILE_ORDER,
	ERX_PROFILE_UNIQUE,
	ERX_PROFILE_REFERS,
	ERX_PROFILE_TOTAL,
	ERX_PROFILE_MALFORMED,	/* no term of the wire grammar, or a map key repeated */
	ERX_PROFILE_SCRATCH,
} erx_profile_reason_t;

/* The reason, the name index (erx_profile_name) of what was judged, and the byte offset. */
struct erx_profile_refusal {
	size_t			 offset;
	erx_profile_reason_t	 reason;
	uint16_t		 kind;
};

typedef enum erx_profile_form {
	ERX_PROFILE_INTEGER,
	ERX_PROFILE_TEXT_FORM,
	ERX_PROFILE_TUPLE,
	ERX_PROFILE_LIST,
	ERX_PROFILE_MAP,
	ERX_PROFILE_UNION,	/* a struct: which, then a case's fields */
	ERX_PROFILE_ATOMS,	/* a union of cases without fields: a uint16_t */
	ERX_PROFILE_BOOLEAN,
	ERX_PROFILE_SIGNAL,	/* an int32_t, the signal's number */
} erx_profile_form_t;

/* A text's rules, checked in this order after its length. */
#define ERX_PROFILE_UTF8_RULE	0x01
#define ERX_PROFILE_NUL_RULE	0x02
#define ERX_PROFILE_ASSIGN_RULE	0x04
#define ERX_PROFILE_PATH_RULE	0x08

/* A text: bytes of the frame, never NUL-terminated. */
struct erx_profile_text {
	const uint8_t		*bytes;
	size_t			 len;
};

/* A tuple's element, a map's field or a union case's field. */
struct erx_profile_field {
	const char		*name;		/* a map's key; NULL otherwise */
	uint16_t		 kind;
	uint16_t		 offset;	/* of the value in its struct */
	uint16_t		 has_offset;	/* an optional key's flag, or NONE */
};

/* A union's case: its atoms, its own first, then its fields. */
struct erx_profile_case {
	const char *const	*atoms;
	const erx_profile_field_t *fields;
	uint16_t		 natoms;
	uint16_t		 nfields;
	uint16_t		 offset;	/* of the case's struct in the union's */
};

/*
 * One kind.  Each form reads its own members: an integer min to max, among
 * values when nvalues is not 0, never except when has_except; a text at
 * most text_max bytes with its rules, adding its length and one to the
 * total sum; a list at most list_max elements of element; a tuple or map
 * its fields; a union its cases.  unique, refers and target are the
 * frame-wide rules: refers indexes the profile's refers rules, and target
 * names the one whose keys this list's elements give.
 */
struct erx_profile_kind {
	const char		*name;
	const uint64_t		*values;
	const erx_profile_field_t *fields;
	const erx_profile_case_t *cases;
	uint64_t		 min;
	uint64_t		 max;
	uint64_t		 except;
	uint32_t		 text_max;
	uint32_t		 list_max;
	erx_profile_form_t	 form;
	uint16_t		 size;		/* bytes of its C value */
	uint16_t		 nvalues;
	uint16_t		 nfields;
	uint16_t		 ncases;
	uint16_t		 element;
	uint16_t		 sum;
	uint16_t		 refers;
	uint16_t		 target;
	uint8_t			 rules;
	bool			 has_except;
	bool			 unique;
	bool			 ascending;
};

/* A refers rule: its kind, and the list whose keys, low to low + range - 1, it names. */
struct erx_profile_refers {
	uint64_t		 low;
	uint32_t		 range;
	uint16_t		 kind;
	uint16_t		 list;
};

struct erx_profile_total {
	uint64_t		 max;
	uint16_t		 name;
};

struct erx_profile_signal {
	const char		*name;
	int32_t			 number;
};

/* A frame: {Tag, Version, Value}, or {Tag, Version, Slot, Value} with slot. */
struct erx_profile_frame {
	const char		*tag;
	uint16_t		 name;
	uint16_t		 kind;
	bool			 slot;
};

/*
 * A profile.  names holds every name a refusal gives: each kind's, then
 * each total's, then each frame's.
 */
struct erx_profile {
	const erx_profile_kind_t *kinds;
	const char *const	*names;
	const erx_profile_refers_t *refers;
	const erx_profile_total_t *totals;
	const erx_profile_signal_t *signals;
	const erx_profile_frame_t *frames;
	uint64_t		 version;
	uint32_t		 frame_max;
	uint16_t		 nkinds;
	uint16_t		 nnames;
	uint16_t		 nrefers;
	uint16_t		 ntotals;
	uint16_t		 nsignals;
	uint16_t		 nframes;
	uint16_t		 slot_kind;
	uint16_t		 unique_kind;	/* NONE when no kind is unique */
	uint16_t		 depth;
};

/*
 * A list's view: where its next element starts and how many are left.
 * Only erx_profile.c changes the fields.
 */
struct erx_profile_list {
	const erx_profile_t	*profile;
	const uint8_t		*frame;
	const uint8_t		*string;	/* a STRING_EXT segment's bytes */
	size_t			 len;
	size_t			 pos;
	uint32_t		 string_left;
	uint32_t		 segment_left;	/* elements left in a LIST_EXT segment */
	uint32_t		 left;		/* elements left in the list */
	uint16_t		 element;
};

/*
 * The scratch erx_profile_check needs for a frame of len bytes: 7 bytes
 * of alignment, 8 for every two bytes of len, and two bitmaps for each
 * refers rule; SIZE_MAX when that overflows.
 */
size_t	erx_profile_scratch_bytes(const erx_profile_t *profile, size_t len);

/*
 * Judges the frame of index frame at bytes.  With less scratch than
 * erx_profile_scratch_bytes promises it refuses with ERX_PROFILE_SCRATCH
 * and writes none of it.  On acceptance it fills *out, the frame's
 * struct, and *slot for a frame with a slot; on refusal *out and *slot are
 * unspecified.
 */
bool	erx_profile_check(const erx_profile_t *profile, uint16_t frame,
	    const uint8_t *bytes, size_t len, void *scratch, size_t scratch_len,
	    uint8_t *slot, void *out, erx_profile_refusal_t *refusal);

/* Reads the next element of an accepted list into *element; false at the end. */
bool	erx_profile_next(erx_profile_list_t *list, void *element);

const char *erx_profile_name(const erx_profile_t *profile, uint16_t name);
const char *erx_profile_reason_name(erx_profile_reason_t reason);

#endif /* !ERX_PROFILE_H */
