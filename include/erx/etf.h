/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

#ifndef ERX_ETF_H
#define ERX_ETF_H

/*
 * erx_etf: the frame grammar's subset of Erlang's external term format, in
 * three parts that share one tokenizer.
 *
 * erx_etf_check judges one encoded term, version byte 131 first, against a
 * grammar and the receiver's limits before anything reads it.  A term is
 * accepted only when it is in the grammar, within the limits, and ends
 * exactly at the end of the input.  It also returns the term's decoded
 * size in heap words exactly as ERTS's size pass (decoded_size in
 * beam/external.c) counts it on a 64-bit build, so a receiver can hold a
 * term to max_message_heap before decoding it.  With rules.accept set it
 * completes the semantic acceptance that ERTS's decoder performs: no map
 * holds two keys equal under exact equality (=:=), whatever their wire
 * forms, so every term it accepts is a term binary_to_term/1 decodes to the
 * same value on a node other than the ones the term names.  A receiver's
 * own pids and references are the exception: ERTS rebuilds them as local
 * ones, refusing some (a pid number past its range) and reading only
 * three words of a four-word reference, so two of its own references that
 * differ only in the fourth word are equal to it and distinct here; an
 * ERTS receiver's decoder refuses those, and stock ERTS writes no local
 * reference of four words.  Without accept it is the funnel's structural
 * pass.
 *
 * The check never recurses.  It walks the term with an explicit stack of
 * at most rules.max_depth frames in the caller's scratch.  A frame is
 * dropped as soon as its last element starts (a tuple's, record's or fun's
 * last element, a map's last value, a list's tail), so long lists and
 * right-nested terms take one frame.  Inside a map key every container
 * keeps its frame until it ends, with accept or without, because with
 * accept the key's identity is computed from all of it, and the depth
 * limit must count the same frames in both modes.
 *
 * erx_etf_next reads a term item by item, in wire order, with no
 * allocation: a container item gives its element count and its elements
 * follow as items.  It is safe on any bytes, but only a checked term is
 * known to be well formed as a whole.
 *
 * The writer appends items to a caller's buffer in the same order.  The
 * caller supplies a container's elements after it; a call whose arguments
 * no term can have, or a buffer too small, makes erx_etf_writer_done fail.
 */

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#define ERX_ETF_VERSION		131
/*
 * The grammar's limits on a single term.  ERTS's decoder enforces the same
 * on atoms, tuples, funs and integers; it caps neither a record's fields
 * nor an export's arity, past which erx_etf refuses what ERTS accepts.
 */
#define ERX_ETF_ATOM_CHARS_MAX	255
#define ERX_ETF_TUPLE_ARITY_MAX	((1u << 24) - 1)
#define ERX_ETF_RECORD_FIELDS_MAX 65535
#define ERX_ETF_FUN_FREE_MAX	255
#define ERX_ETF_EXPORT_ARITY_MAX 255
#define ERX_ETF_BIG_BYTES_MAX	(65535u * 8)
#define ERX_ETF_REF_WORDS	4
#define ERX_ETF_UNIQ_BYTES	16
/* The largest input erx_etf_check reads: it keeps 32-bit offsets into it. */
#define ERX_ETF_INPUT_MAX	UINT32_MAX

typedef struct erx_etf_fun erx_etf_fun_t;
typedef struct erx_etf_item erx_etf_item_t;
typedef struct erx_etf_pid erx_etf_pid_t;
typedef struct erx_etf_reader erx_etf_reader_t;
typedef struct erx_etf_ref erx_etf_ref_t;
typedef struct erx_etf_result erx_etf_result_t;
typedef struct erx_etf_rules erx_etf_rules_t;
typedef struct erx_etf_writer erx_etf_writer_t;

/*
 * The grammars, each the one above it less some kinds: the domain grammar
 * for frames to a domain, the system grammar for frames to the system
 * domain (no funs or exports), the host grammar for the host link (no
 * pids or references either).
 */
typedef enum erx_etf_grammar {
	ERX_ETF_DOMAIN,
	ERX_ETF_SYSTEM,
	ERX_ETF_HOST,
} erx_etf_grammar_t;

typedef enum erx_etf_verdict {
	ERX_ETF_ACCEPTED,
	ERX_ETF_MALFORMED,	/* outside the grammar: end the connection */
	ERX_ETF_OVER_LIMIT,	/* in the grammar, past a receiver's limit */
} erx_etf_verdict_t;

/* Why a term was refused; ERX_ETF_OK for an accepted one. */
typedef enum erx_etf_reason {
	ERX_ETF_OK,
	ERX_ETF_ERR_VERSION_BYTE,	/* no version byte 131 */
	ERX_ETF_ERR_TRUNCATED,	/* the input ends inside the term */
	ERX_ETF_ERR_TRAILING,	/* bytes after the term */
	ERX_ETF_ERR_TAG,		/* a tag outside the grammar */
	ERX_ETF_ERR_ATOM,		/* invalid UTF-8, or over 255 characters */
	ERX_ETF_ERR_FLOAT,		/* not finite */
	ERX_ETF_ERR_BITS,		/* a bitstring's trailing bits not 1 to 8 */
	ERX_ETF_ERR_BIG,		/* an integer over ERTS's largest */
	ERX_ETF_ERR_ARITY,		/* a tuple, map or record past ERTS's limit */
	ERX_ETF_ERR_NODE,		/* a node name not an identifier at the host */
	ERX_ETF_ERR_REF_LEN,	/* a reference of other than 4 words */
	ERX_ETF_ERR_FUN,		/* a fun or export field of the wrong kind */
	ERX_ETF_ERR_RECORD,		/* a record's flags, or a field name repeated */
	ERX_ETF_ERR_MAP_KEY,	/* two map keys equal under =:= */
	ERX_ETF_ERR_DEPTH,		/* over rules.max_depth frames */
	ERX_ETF_ERR_WORDS,		/* over rules.max_words decoded */
	ERX_ETF_ERR_SCRATCH,	/* the caller's scratch is too small */
	ERX_ETF_ERR_TOO_LONG,	/* an input over ERX_ETF_INPUT_MAX bytes */
} erx_etf_reason_t;

/*
 * What the receiver admits.  host names the machine: every pid's and
 * reference's node atom must be an identifier, "@" and exactly these
 * bytes.  An identifier is 1 to 63 bytes of [a-z0-9_-], starting with a
 * letter or digit.
 */
struct erx_etf_rules {
	const char		*host;
	size_t			 host_len;
	uint64_t		 max_words;
	uint32_t		 max_depth;
	erx_etf_grammar_t	 grammar;
	bool			 accept;
};

/*
 * The verdict, its reason, the offset in the input at which the check
 * decided it, and the decoded size in words: the whole term's when
 * accepted, what was counted so far otherwise.
 */
struct erx_etf_result {
	uint64_t		 words;
	size_t			 offset;
	erx_etf_verdict_t	 verdict;
	erx_etf_reason_t	 reason;
};

/*
 * Judges len bytes at term.  scratch holds the explicit stack and the
 * records the check keeps for map keys and record field names;
 * erx_etf_scratch_bytes(rules) bytes always suffice, since what a map or a
 * record keeps is bounded by the words it is charged.  scratch may have any
 * alignment: the check aligns its stack inside it, and the size
 * erx_etf_scratch_bytes returns includes that padding.  Pure: it reads only
 * its arguments and writes only scratch and *result.
 */
erx_etf_verdict_t erx_etf_check(const uint8_t *term, size_t len,
    const erx_etf_rules_t *rules, void *scratch, size_t scratch_len,
    erx_etf_result_t *result);
size_t erx_etf_scratch_bytes(const erx_etf_rules_t *rules);

/* The kinds of item, and the fields of erx_etf_item_t each one sets. */
typedef enum erx_etf_kind {
	ERX_ETF_INTEGER,	/* u.integer: any encoding whose value fits */
	ERX_ETF_BIG,		/* u.data: magnitude, little-endian; negative */
	ERX_ETF_FLOAT,		/* u.real */
	ERX_ETF_ATOM,		/* u.data: the name's UTF-8 bytes */
	ERX_ETF_BINARY,		/* u.data: bytes; trailing_bits used of the last */
	ERX_ETF_TUPLE,		/* count elements follow */
	ERX_ETF_NIL,
	ERX_ETF_LIST,		/* count elements follow, then the tail */
	ERX_ETF_STRING,		/* u.data: a proper list of these bytes */
	ERX_ETF_MAP,		/* count pairs follow, each key then value */
	ERX_ETF_RECORD,		/* module, name, count field names, count values */
	ERX_ETF_PID,		/* u.pid */
	ERX_ETF_REF,		/* u.ref */
	ERX_ETF_FUN,		/* u.fun; module, old index, old uniq, creator,
				   count free variables follow */
	ERX_ETF_EXPORT,		/* module, function and arity follow */
} erx_etf_kind_t;

struct erx_etf_pid {
	const uint8_t		*node;
	size_t			 node_len;
	uint32_t		 id;
	uint32_t		 serial;
	uint32_t		 creation;
};

struct erx_etf_ref {
	const uint8_t		*node;
	size_t			 node_len;
	uint32_t		 creation;
	uint32_t		 words[ERX_ETF_REF_WORDS];
};

struct erx_etf_fun {
	const uint8_t		*uniq;		/* ERX_ETF_UNIQ_BYTES bytes */
	uint32_t		 index;
	uint8_t			 arity;
};

/*
 * One item.  Pointers point into the input, so they live as long as it
 * does.  For a binary, trailing_bits is 8 when the last byte is whole (and
 * for the empty binary); the unused low bits of a partial last byte are
 * whatever the input holds.
 */
struct erx_etf_item {
	union {
		int64_t		 integer;
		double		 real;
		struct {
			const uint8_t	*bytes;
			size_t		 len;
			uint8_t		 trailing_bits;
			bool		 negative;
		} data;
		erx_etf_pid_t	 pid;
		erx_etf_ref_t	 ref;
		erx_etf_fun_t	 fun;
		bool		 exported;	/* a record's flag */
	} u;
	uint32_t		 count;
	erx_etf_kind_t		 kind;
};

/* A position in an encoded term; only erx_etf.c changes the fields. */
struct erx_etf_reader {
	const uint8_t		*bytes;
	size_t			 len;
	size_t			 pos;
};

typedef enum erx_etf_step {
	ERX_ETF_STEP_ITEM,	/* *item is the next item */
	ERX_ETF_STEP_END,	/* the input is consumed */
	ERX_ETF_STEP_ERROR,	/* the next bytes are no item; see *reason */
} erx_etf_step_t;

/* False when the input does not start with the version byte. */
bool erx_etf_reader_init(erx_etf_reader_t *reader, const uint8_t *term,
    size_t len);
erx_etf_step_t erx_etf_next(erx_etf_reader_t *reader, erx_etf_item_t *item,
    erx_etf_reason_t *reason);

/* A buffer being written; only erx_etf.c changes the fields. */
struct erx_etf_writer {
	uint8_t			*buf;
	size_t			 cap;
	size_t			 len;
	bool			 failed;
};

/* Starts a term in buf with its version byte. */
void erx_etf_writer_init(erx_etf_writer_t *writer, uint8_t *buf, size_t cap);
/* The term's length, or false when a call failed. */
bool erx_etf_writer_done(const erx_etf_writer_t *writer, size_t *len);

void erx_etf_put_atom(erx_etf_writer_t *writer, const char *name,
    size_t len);
void erx_etf_put_big(erx_etf_writer_t *writer, bool negative,
    const uint8_t *magnitude, size_t len);
void erx_etf_put_binary(erx_etf_writer_t *writer, const void *bytes,
    size_t len);
void erx_etf_put_bits(erx_etf_writer_t *writer, const void *bytes,
    size_t len, unsigned trailing_bits);
void erx_etf_put_export(erx_etf_writer_t *writer);
void erx_etf_put_float(erx_etf_writer_t *writer, double value);
void erx_etf_put_fun(erx_etf_writer_t *writer, const erx_etf_fun_t *fun,
    uint32_t free_count);
void erx_etf_put_integer(erx_etf_writer_t *writer, int64_t value);
void erx_etf_put_list(erx_etf_writer_t *writer, uint32_t count);
void erx_etf_put_map(erx_etf_writer_t *writer, uint32_t pairs);
void erx_etf_put_nil(erx_etf_writer_t *writer);
void erx_etf_put_pid(erx_etf_writer_t *writer, const erx_etf_pid_t *pid);
void erx_etf_put_record(erx_etf_writer_t *writer, uint32_t fields,
    bool exported);
void erx_etf_put_ref(erx_etf_writer_t *writer, const erx_etf_ref_t *ref);
void erx_etf_put_string(erx_etf_writer_t *writer, const uint8_t *bytes,
    size_t len);
void erx_etf_put_tuple(erx_etf_writer_t *writer, uint32_t arity);

#endif /* !ERX_ETF_H */
