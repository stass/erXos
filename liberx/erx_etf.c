/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

/*
 * The frame grammar's subset of the external term format: one tokenizer
 * (etf_token), the check built on it, the item reader and the writer.
 * include/erx/etf.h states the contracts.
 *
 * How the check decides map-key equality.  Two keys are equal under =:=
 * exactly when their canonical forms are: an integer by its sign and
 * magnitude whatever its encoding, a list by its elements and final tail
 * however LIST_EXT and STRING_EXT tails split it, a bitstring with 8
 * trailing bits as the binary it is, a map by its pairs in any order, a fun
 * by its entry (module, index, arity, uniq) and free variables, but not by
 * its old index, old uniq or creator, which ERTS's decoder discards.  Each
 * key gets a 16-byte BLAKE3 digest of its canonical form, built bottom up
 * as the key is read: a leaf hashes its canonical bytes, a container
 * chains its elements' digests onto a digest of its kind and header, and a
 * map hashes its pairs sorted by key digest.  Equal keys therefore always
 * have equal digests, so no duplicate is accepted; two different keys with
 * equal digests would be a BLAKE3 collision, and would only make the check
 * refuse a term binary_to_term accepts.
 */

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <string.h>

#include "blake3/blake3.h"
#include "erx/cdefs.h"
#include "erx/etf.h"

/* Tags of the grammar, from OTP's erl_ext_dist.md. */
enum {
	TAG_RECORD = 67,
	TAG_NEW_FLOAT = 70,
	TAG_BIT_BINARY = 77,
	TAG_NEW_PID = 88,
	TAG_NEWER_REFERENCE = 90,
	TAG_SMALL_INTEGER = 97,
	TAG_INTEGER = 98,
	TAG_SMALL_TUPLE = 104,
	TAG_LARGE_TUPLE = 105,
	TAG_NIL = 106,
	TAG_STRING = 107,
	TAG_LIST = 108,
	TAG_BINARY = 109,
	TAG_SMALL_BIG = 110,
	TAG_LARGE_BIG = 111,
	TAG_NEW_FUN = 112,
	TAG_EXPORT = 113,
	TAG_MAP = 116,
	TAG_ATOM_UTF8 = 118,
	TAG_SMALL_ATOM_UTF8 = 119,
};

/*
 * ERTS's heap sizes in words on a 64-bit build, as its size pass counts
 * them: a heap binary of up to 64 bytes takes a two-word header and its
 * bytes, a larger one a reference and a sub-binary; an external pid and a
 * four-word reference take a three-word head and their data; a small map
 * of up to 32 pairs takes a header and a keys tuple, a larger one ERTS's
 * estimate for a hash map; a native record takes an instance and a
 * definition.
 */
#define WORDS_HEAP_BINARY_MAX	64
#define WORDS_HEAP_BINARY_HEAD	2
#define WORDS_REFC_BINARY	8
#define WORDS_FLOAT		2
#define WORDS_PID		4
#define WORDS_REF		6
#define WORDS_FUN_HEAD		2
#define WORDS_SMALL_MAP_MAX	32

/* ERTS's small integers on a 64-bit build: 60 bits, signed. */
#define SMALL_MAX		((INT64_C(1) << 59) - 1)
#define SMALL_MIN		(-(INT64_C(1) << 59))

#define IDENT_MAX		63
#define DIGEST			16

/*
 * The first byte of every hashed input says what it is, so no two kinds of
 * input can be equal: leaves and container headers use these letters, a
 * chain step the byte CHAIN.
 */
enum {
	CANON_INTEGER = 'i',
	CANON_FLOAT = 'f',
	CANON_ATOM = 'a',
	CANON_BITS = 'b',
	CANON_PID = 'p',
	CANON_REF = 'x',
	CANON_NIL = 'n',
	CANON_TUPLE = 't',
	CANON_LIST = 'l',
	CANON_MAP = 'm',
	CANON_RECORD = 'r',
	CANON_RECORD_EXPORTED = 'R',
	CANON_FUN = 'F',
	CANON_EXPORT = 'e',
	CANON_CHAIN = 0xff,
};

typedef struct etf_check etf_check_t;
typedef struct etf_frame etf_frame_t;
typedef struct etf_token etf_token_t;

/* One item as the tokenizer read it, with what ERTS charges for it. */
struct etf_token {
	erx_etf_item_t		 item;
	uint64_t		 words;
};

/*
 * An open container.  left counts the elements not yet started, a list's
 * tail included, and drops as each one starts, so an element that ends
 * while left is 0 is the last (a list's tail); a frame whose left is 0 is
 * never the top when the next item is read, because its last element is
 * either a leaf, which ends it at once, or a container above it.  next is
 * the index of the next element.  base is where the frame's entries start
 * on the entry stack: a map's key digests (with value digests when the map
 * is inside a key), or a record's field-name offsets.
 *
 * in_key marks a frame inside a map key.  Such a frame stays on the stack
 * until it ends, in both modes, so the depth limit counts every container
 * of a key alike with and without accept; with accept it also computes
 * its own digest, in chain.
 */
struct etf_frame {
	uint8_t			 chain[DIGEST];
	uint64_t		 left;
	size_t			 base;
	uint32_t		 next;
	uint32_t		 count;		/* tuple arity, map pairs, record fields */
	uint32_t		 elements;	/* a list's elements so far */
	erx_etf_kind_t		 kind;
	bool			 in_key;
};

struct etf_check {
	erx_blake3_ctx_t	 hasher;
	const erx_etf_rules_t	*rules;
	const uint8_t		*term;
	size_t			 len;
	etf_frame_t		*frames;
	size_t			 frames_cap;
	uint8_t			*entries;
	size_t			 entries_cap;
	size_t			 entries_len;
	uint64_t		 words;
	uint32_t		 depth;
};

typedef int (*etf_cmp_t)(const void *, const uint8_t *, const uint8_t *);

/* Whether the frame computes a digest: with accept, inside a map key. */
static inline bool
digesting(const etf_check_t *c, const etf_frame_t *f)
{
	return (c->rules->accept && f->in_key);
}

static erx_etf_reason_t	 admit(etf_check_t *, const etf_frame_t *, uint32_t,
			    const etf_token_t *);
static erx_etf_reason_t	 note_field_name(etf_check_t *, etf_frame_t *,
			    uint32_t, size_t);
static int		 atom_cmp(const void *, const uint8_t *, const uint8_t *);
static const uint8_t	*atom_text_at(const uint8_t *, uint32_t, size_t *);
static void		 chain(uint8_t [DIGEST], const uint8_t [DIGEST]);
static void		 chain_bytes(etf_check_t *, uint8_t [DIGEST],
			    const uint8_t *, size_t);
static erx_etf_reason_t	 check_names(etf_check_t *, etf_frame_t *);
static erx_etf_reason_t	 child_constraint(const etf_frame_t *, uint32_t,
			    const erx_etf_item_t *);
static void		 digest_leaf(etf_check_t *, const erx_etf_item_t *,
			    uint8_t [DIGEST]);
static void		 digest_nil(etf_check_t *, uint8_t [DIGEST]);
static void		 digest_magnitude(etf_check_t *, bool, const uint8_t *,
			    size_t, uint8_t [DIGEST]);
static int		 digest_cmp(const void *, const uint8_t *,
			    const uint8_t *);
static erx_etf_reason_t	 deliver(etf_check_t *, etf_frame_t *,
			    const uint8_t [DIGEST]);
static erx_etf_reason_t	 ended(etf_check_t *, bool, const uint8_t [DIGEST]);
static uint8_t		*entry_push(etf_check_t *, size_t);
static erx_etf_reason_t	 finish(etf_check_t *, etf_frame_t *,
			    uint8_t [DIGEST]);
static size_t		 frames_for(const erx_etf_rules_t *, size_t);
static void		 frame_open(etf_check_t *, etf_frame_t *,
			    const erx_etf_item_t *, bool);
static bool		 has_equal_neighbours(const uint8_t *, size_t, size_t,
			    etf_cmp_t, const void *);
static bool		 node_ok(const erx_etf_rules_t *, const uint8_t *,
			    size_t);
static bool		 opens_frame(const erx_etf_item_t *);
static void		 sort_entries(uint8_t *, size_t, size_t, etf_cmp_t,
			    const void *);
static erx_etf_reason_t	 token(const uint8_t *, size_t, size_t *,
			    etf_token_t *);
static erx_etf_reason_t	 token_atom(const uint8_t *, size_t, size_t *,
			    const uint8_t **, size_t *);
static erx_etf_verdict_t verdict_of(erx_etf_reason_t);
static uint64_t		 words_of_bytes(uint64_t);

/* Big-endian fields of the wire format. */
static uint16_t
get_u16(const uint8_t *p)
{
	return ((uint16_t)((uint16_t)p[0] << 8 | p[1]));
}

static uint32_t
get_u32(const uint8_t *p)
{
	return ((uint32_t)p[0] << 24 | (uint32_t)p[1] << 16 |
	    (uint32_t)p[2] << 8 | p[3]);
}

static uint64_t
words_of_bytes(uint64_t bytes)
{
	return (bytes / 8 + (bytes % 8 != 0));
}

/*
 * Validates an atom's text: UTF-8 with no overlong form, surrogate or code
 * point past U+10FFFF, of at most ERX_ETF_ATOM_CHARS_MAX characters.
 */
static bool
atom_text_ok(const uint8_t *s, size_t len)
{
	size_t chars, i, n;
	uint8_t lo, hi;

	for (i = 0, chars = 0; i < len; i += n, chars++) {
		lo = 0x80;
		hi = 0xbf;
		if (s[i] < 0x80) {
			n = 1;
		} else if (s[i] >= 0xc2 && s[i] <= 0xdf) {
			n = 2;
		} else if (s[i] >= 0xe0 && s[i] <= 0xef) {
			n = 3;
			if (s[i] == 0xe0)
				lo = 0xa0;
			else if (s[i] == 0xed)
				hi = 0x9f;
		} else if (s[i] >= 0xf0 && s[i] <= 0xf4) {
			n = 4;
			if (s[i] == 0xf0)
				lo = 0x90;
			else if (s[i] == 0xf4)
				hi = 0x8f;
		} else {
			return (false);
		}
		if (n > len - i)
			return (false);
		/* Only the second byte has a narrowed range. */
		for (size_t k = 1; k < n; k++) {
			if (s[i + k] < (k == 1 ? lo : 0x80) ||
			    s[i + k] > (k == 1 ? hi : 0xbf))
				return (false);
		}
	}
	return (chars <= ERX_ETF_ATOM_CHARS_MAX);
}

/* An atom in one of the grammar's two encodings, tag included. */
static erx_etf_reason_t
token_atom(const uint8_t *b, size_t len, size_t *pos, const uint8_t **text,
    size_t *text_len)
{
	size_t p, n;

	p = *pos;
	if (p >= len)
		return (ERX_ETF_ERR_TRUNCATED);
	if (b[p] == TAG_SMALL_ATOM_UTF8) {
		if (len - p < 2)
			return (ERX_ETF_ERR_TRUNCATED);
		n = b[p + 1];
		p += 2;
	} else if (b[p] == TAG_ATOM_UTF8) {
		if (len - p < 3)
			return (ERX_ETF_ERR_TRUNCATED);
		n = get_u16(b + p + 1);
		p += 3;
		/* ERTS refuses a length no 255 characters can need. */
		if (n > 4 * ERX_ETF_ATOM_CHARS_MAX)
			return (ERX_ETF_ERR_ATOM);
	} else {
		return (ERX_ETF_ERR_TAG);
	}
	if (n > len - p)
		return (ERX_ETF_ERR_TRUNCATED);
	if (!atom_text_ok(b + p, n))
		return (ERX_ETF_ERR_ATOM);
	*text = b + p;
	*text_len = n;
	*pos = p + n;
	return (ERX_ETF_OK);
}

/*
 * An integer of a big encoding: an INTEGER item when its value fits in 64
 * bits, else a BIG item with its magnitude stripped of high zero bytes.
 */
static void
big_item(erx_etf_item_t *item, bool negative, const uint8_t *mag, size_t n)
{
	uint64_t v;

	while (n > 0 && mag[n - 1] == 0)
		n--;
	if (n <= 8) {
		v = 0;
		for (size_t i = n; i > 0; i--)
			v = v << 8 | mag[i - 1];
		if (!negative && v <= (uint64_t)INT64_MAX) {
			item->kind = ERX_ETF_INTEGER;
			item->u.integer = (int64_t)v;
			return;
		}
		if (negative && v <= (uint64_t)INT64_MAX + 1) {
			item->kind = ERX_ETF_INTEGER;
			item->u.integer = v == (uint64_t)INT64_MAX + 1 ?
			    INT64_MIN : -(int64_t)v;
			return;
		}
	}
	item->kind = ERX_ETF_BIG;
	item->u.data.bytes = mag;
	item->u.data.len = n;
	item->u.data.negative = negative;
}

/*
 * Reads one item at *pos: its tag and fixed fields, and a leaf's bytes, but
 * no container's elements.  A container whose elements cannot fit in what
 * remains, at a byte each at least, is truncated, as ERTS's size pass
 * finds before it counts the container's words.  Grammar-agnostic: every
 * tag of the domain grammar is an item.
 */
static erx_etf_reason_t
token(const uint8_t *b, size_t len, size_t *pos, etf_token_t *t)
{
	erx_etf_item_t *item;
	erx_etf_reason_t reason;
	uint64_t bits, need;
	size_t n, p, rest;
	uint8_t tag;

	item = &t->item;
	*item = (erx_etf_item_t){ .count = 0 };
	t->words = 0;
	p = *pos;
	if (p >= len)
		return (ERX_ETF_ERR_TRUNCATED);
	tag = b[p];
	rest = len - p - 1;
	switch (tag) {
	case TAG_SMALL_INTEGER:
		if (rest < 1)
			return (ERX_ETF_ERR_TRUNCATED);
		item->kind = ERX_ETF_INTEGER;
		item->u.integer = b[p + 1];
		p += 2;
		break;
	case TAG_INTEGER:
		if (rest < 4)
			return (ERX_ETF_ERR_TRUNCATED);
		item->kind = ERX_ETF_INTEGER;
		item->u.integer = (int32_t)get_u32(b + p + 1);
		p += 5;
		break;
	case TAG_SMALL_BIG:
	case TAG_LARGE_BIG:
		if (tag == TAG_SMALL_BIG) {
			if (rest < 2)
				return (ERX_ETF_ERR_TRUNCATED);
			n = b[p + 1];
			p += 2;
			t->words = 1 + words_of_bytes(n);
		} else {
			if (rest < 5)
				return (ERX_ETF_ERR_TRUNCATED);
			n = get_u32(b + p + 1);
			if (n > ERX_ETF_BIG_BYTES_MAX)
				return (ERX_ETF_ERR_BIG);
			p += 5;
			t->words = 2 + words_of_bytes(n);
		}
		/* Any nonzero sign byte is negative, as ERTS reads it. */
		if (n > len - p - 1)
			return (ERX_ETF_ERR_TRUNCATED);
		big_item(item, b[p] != 0, b + p + 1, n);
		p += 1 + n;
		break;
	case TAG_NEW_FLOAT:
		if (rest < 8)
			return (ERX_ETF_ERR_TRUNCATED);
		bits = (uint64_t)get_u32(b + p + 1) << 32 | get_u32(b + p + 5);
		if ((bits >> 52 & 0x7ff) == 0x7ff)
			return (ERX_ETF_ERR_FLOAT);
		item->kind = ERX_ETF_FLOAT;
		memcpy(&item->u.real, &bits, sizeof(item->u.real));
		t->words = WORDS_FLOAT;
		p += 9;
		break;
	case TAG_SMALL_ATOM_UTF8:
	case TAG_ATOM_UTF8:
		reason = token_atom(b, len, &p, &item->u.data.bytes,
		    &item->u.data.len);
		if (reason != ERX_ETF_OK)
			return (reason);
		item->kind = ERX_ETF_ATOM;
		break;
	case TAG_BINARY:
	case TAG_BIT_BINARY:
		if (rest < (tag == TAG_BINARY ? 4u : 5u))
			return (ERX_ETF_ERR_TRUNCATED);
		n = get_u32(b + p + 1);
		item->u.data.trailing_bits = 8;
		if (tag == TAG_BIT_BINARY) {
			item->u.data.trailing_bits = b[p + 5];
			if (n == 0 || b[p + 5] < 1 || b[p + 5] > 8)
				return (ERX_ETF_ERR_BITS);
			p++;
		}
		p += 5;
		if (n > len - p)
			return (ERX_ETF_ERR_TRUNCATED);
		item->kind = ERX_ETF_BINARY;
		item->u.data.bytes = b + p;
		item->u.data.len = n;
		t->words = n <= WORDS_HEAP_BINARY_MAX ?
		    WORDS_HEAP_BINARY_HEAD + words_of_bytes(n) :
		    WORDS_REFC_BINARY;
		p += n;
		break;
	case TAG_SMALL_TUPLE:
	case TAG_LARGE_TUPLE:
		if (tag == TAG_SMALL_TUPLE) {
			if (rest < 1)
				return (ERX_ETF_ERR_TRUNCATED);
			n = b[p + 1];
			p += 2;
		} else {
			if (rest < 4)
				return (ERX_ETF_ERR_TRUNCATED);
			n = get_u32(b + p + 1);
			if (n > ERX_ETF_TUPLE_ARITY_MAX)
				return (ERX_ETF_ERR_ARITY);
			p += 5;
		}
		if (n > len - p)
			return (ERX_ETF_ERR_TRUNCATED);
		item->kind = ERX_ETF_TUPLE;
		item->count = (uint32_t)n;
		t->words = n > 0 ? n + 1 : 0;
		break;
	case TAG_NIL:
		item->kind = ERX_ETF_NIL;
		p++;
		break;
	case TAG_STRING:
		if (rest < 2)
			return (ERX_ETF_ERR_TRUNCATED);
		n = get_u16(b + p + 1);
		p += 3;
		if (n > len - p)
			return (ERX_ETF_ERR_TRUNCATED);
		item->kind = ERX_ETF_STRING;
		item->u.data.bytes = b + p;
		item->u.data.len = n;
		t->words = 2 * (uint64_t)n;
		p += n;
		break;
	case TAG_LIST:
		if (rest < 4)
			return (ERX_ETF_ERR_TRUNCATED);
		n = get_u32(b + p + 1);
		p += 5;
		/* The elements and the tail. */
		if (n >= len - p)
			return (ERX_ETF_ERR_TRUNCATED);
		item->kind = ERX_ETF_LIST;
		item->count = (uint32_t)n;
		t->words = 2 * (uint64_t)n;
		break;
	case TAG_MAP:
		if (rest < 4)
			return (ERX_ETF_ERR_TRUNCATED);
		n = get_u32(b + p + 1);
		if (n >> 31 != 0)
			return (ERX_ETF_ERR_ARITY);
		p += 5;
		if (2 * (uint64_t)n > len - p)
			return (ERX_ETF_ERR_TRUNCATED);
		item->kind = ERX_ETF_MAP;
		item->count = (uint32_t)n;
		if (n <= WORDS_SMALL_MAP_MAX)
			t->words = 3 + n + (n > 0 ? 1 + n : 0);
		else
			t->words = 3 * (uint64_t)n + 2 * (uint64_t)n * 4 / 10;
		break;
	case TAG_RECORD:
		if (rest < 5)
			return (ERX_ETF_ERR_TRUNCATED);
		n = get_u32(b + p + 1);
		if (n > ERX_ETF_RECORD_FIELDS_MAX)
			return (ERX_ETF_ERR_ARITY);
		if (b[p + 5] > 1)
			return (ERX_ETF_ERR_RECORD);
		p += 6;
		/* Module, name, field names and values. */
		need = 2 + 2 * (uint64_t)n;
		if (need > len - p)
			return (ERX_ETF_ERR_TRUNCATED);
		item->kind = ERX_ETF_RECORD;
		item->count = (uint32_t)n;
		item->u.exported = b[p - 1] == 1;
		t->words = (2 + n) + (6 + n) + (n > 0 ? 1 + n : 0);
		break;
	case TAG_NEW_PID:
		p++;
		reason = token_atom(b, len, &p, &item->u.pid.node,
		    &item->u.pid.node_len);
		if (reason != ERX_ETF_OK)
			return (reason);
		if (len - p < 12)
			return (ERX_ETF_ERR_TRUNCATED);
		item->kind = ERX_ETF_PID;
		item->u.pid.id = get_u32(b + p);
		item->u.pid.serial = get_u32(b + p + 4);
		item->u.pid.creation = get_u32(b + p + 8);
		t->words = WORDS_PID;
		p += 12;
		break;
	case TAG_NEWER_REFERENCE:
		if (rest < 2)
			return (ERX_ETF_ERR_TRUNCATED);
		if (get_u16(b + p + 1) != ERX_ETF_REF_WORDS)
			return (ERX_ETF_ERR_REF_LEN);
		p += 3;
		reason = token_atom(b, len, &p, &item->u.ref.node,
		    &item->u.ref.node_len);
		if (reason != ERX_ETF_OK)
			return (reason);
		if (len - p < 4 + 4 * ERX_ETF_REF_WORDS)
			return (ERX_ETF_ERR_TRUNCATED);
		item->kind = ERX_ETF_REF;
		item->u.ref.creation = get_u32(b + p);
		for (size_t i = 0; i < ERX_ETF_REF_WORDS; i++)
			item->u.ref.words[i] = get_u32(b + p + 4 + 4 * i);
		t->words = WORDS_REF;
		p += 4 + 4 * ERX_ETF_REF_WORDS;
		break;
	case TAG_NEW_FUN:
		/* Size (which ERTS ignores), arity, uniq, index, free count. */
		if (rest < 4 + 1 + ERX_ETF_UNIQ_BYTES + 4 + 4)
			return (ERX_ETF_ERR_TRUNCATED);
		item->kind = ERX_ETF_FUN;
		item->u.fun.arity = b[p + 5];
		item->u.fun.uniq = b + p + 6;
		item->u.fun.index = get_u32(b + p + 22);
		n = get_u32(b + p + 26);
		if (n > ERX_ETF_FUN_FREE_MAX)
			return (ERX_ETF_ERR_FUN);
		p += 30;
		/* Module, old index, old uniq, creator, free variables. */
		if (4 + n > len - p)
			return (ERX_ETF_ERR_TRUNCATED);
		item->count = (uint32_t)n;
		t->words = WORDS_FUN_HEAD + n;
		break;
	case TAG_EXPORT:
		item->kind = ERX_ETF_EXPORT;
		p++;
		break;
	default:
		return (ERX_ETF_ERR_TAG);
	}
	*pos = p;
	return (ERX_ETF_OK);
}

/*
 * A node name an identifier, "@" and the rules' host: the identifier 1 to
 * IDENT_MAX bytes of [a-z0-9_-], its first a letter or digit.
 */
static bool
node_ok(const erx_etf_rules_t *rules, const uint8_t *node, size_t len)
{
	size_t at;
	uint8_t c;

	if (rules->host == NULL || rules->host_len == 0)
		return (false);
	for (at = 0; at < len && node[at] != '@'; at++) {
		c = node[at];
		if (!((c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') ||
		    (at > 0 && (c == '_' || c == '-'))))
			return (false);
	}
	if (at == 0 || at > IDENT_MAX || at == len)
		return (false);
	return (len - at - 1 == rules->host_len &&
	    memcmp(node + at + 1, rules->host, rules->host_len) == 0);
}

static bool
opens_frame(const erx_etf_item_t *item)
{
	switch (item->kind) {
	case ERX_ETF_TUPLE:
	case ERX_ETF_MAP:
		return (item->count > 0);
	case ERX_ETF_LIST:
	case ERX_ETF_RECORD:
	case ERX_ETF_FUN:
	case ERX_ETF_EXPORT:
		return (true);
	default:
		return (false);
	}
}

/*
 * The fields of a record, a fun and an export that must be particular
 * leaves: a record's module, name and field names are atoms; a fun's
 * module is an atom, its old index and old uniq ERTS small integers and
 * its creator a pid; an export's module and function are atoms and its
 * arity an integer from 0 to ERX_ETF_EXPORT_ARITY_MAX.
 */
static erx_etf_reason_t
child_constraint(const etf_frame_t *f, uint32_t index,
    const erx_etf_item_t *it)
{
	bool small;

	small = it->kind == ERX_ETF_INTEGER && it->u.integer >= SMALL_MIN &&
	    it->u.integer <= SMALL_MAX;
	switch (f->kind) {
	case ERX_ETF_RECORD:
		if (index < 2 + (uint64_t)f->count && it->kind != ERX_ETF_ATOM)
			return (ERX_ETF_ERR_RECORD);
		return (ERX_ETF_OK);
	case ERX_ETF_FUN:
		if ((index == 0 && it->kind != ERX_ETF_ATOM) ||
		    ((index == 1 || index == 2) && !small) ||
		    (index == 3 && it->kind != ERX_ETF_PID))
			return (ERX_ETF_ERR_FUN);
		return (ERX_ETF_OK);
	case ERX_ETF_EXPORT:
		if ((index < 2 && it->kind != ERX_ETF_ATOM) ||
		    (index == 2 && (!small || it->u.integer < 0 ||
		    it->u.integer > ERX_ETF_EXPORT_ARITY_MAX)))
			return (ERX_ETF_ERR_FUN);
		return (ERX_ETF_OK);
	default:
		return (ERX_ETF_OK);
	}
}

/*
 * Whether the item may stand where it does: its kind is in the grammar,
 * its node names are the host's, it suits its field of a record, fun or
 * export (f is its container and index its element index there, or f is
 * NULL at the top), and the words it adds stay within the limit, to which
 * they are then charged.
 */
static erx_etf_reason_t
admit(etf_check_t *c, const etf_frame_t *f, uint32_t index,
    const etf_token_t *t)
{
	const erx_etf_item_t *item;
	erx_etf_reason_t reason;
	erx_etf_grammar_t grammar;
	uint64_t words;
	bool overflow;

	item = &t->item;
	grammar = c->rules->grammar;
	if ((item->kind == ERX_ETF_FUN || item->kind == ERX_ETF_EXPORT) &&
	    grammar != ERX_ETF_DOMAIN)
		return (ERX_ETF_ERR_TAG);
	if ((item->kind == ERX_ETF_PID || item->kind == ERX_ETF_REF) &&
	    grammar == ERX_ETF_HOST)
		return (ERX_ETF_ERR_TAG);
	if (item->kind == ERX_ETF_PID &&
	    !node_ok(c->rules, item->u.pid.node, item->u.pid.node_len))
		return (ERX_ETF_ERR_NODE);
	if (item->kind == ERX_ETF_REF &&
	    !node_ok(c->rules, item->u.ref.node, item->u.ref.node_len))
		return (ERX_ETF_ERR_NODE);
	if (f != NULL) {
		reason = child_constraint(f, index, item);
		if (reason != ERX_ETF_OK)
			return (reason);
	}
	overflow = __builtin_add_overflow(c->words, t->words, &words);
	if (overflow || words > c->rules->max_words)
		return (ERX_ETF_ERR_WORDS);
	c->words = words;
	return (ERX_ETF_OK);
}

/*
 * A record's field names must be distinct, as ERTS's decoder requires.
 * Each name, an atom element with index 2 to count + 1, is kept on the
 * entry stack by its offset in the term; after the last, the offsets are
 * sorted by the names' text and dropped.  Names are leaves, so nothing
 * else pushes entries between a record's first name and its last.
 */
static erx_etf_reason_t
note_field_name(etf_check_t *c, etf_frame_t *f, uint32_t index, size_t offset)
{
	uint8_t *slot;
	uint32_t off32;

	if (f->kind != ERX_ETF_RECORD || index < 2 ||
	    index >= 2 + (uint64_t)f->count)
		return (ERX_ETF_OK);
	slot = entry_push(c, sizeof(off32));
	if (slot == NULL)
		return (ERX_ETF_ERR_SCRATCH);
	off32 = (uint32_t)offset;
	memcpy(slot, &off32, sizeof(off32));
	if (index < 1 + f->count)
		return (ERX_ETF_OK);
	return (check_names(c, f));
}

/* Reserves n bytes on the entry stack, or NULL when scratch is full. */
static uint8_t *
entry_push(etf_check_t *c, size_t n)
{
	uint8_t *slot;

	if (n > c->entries_cap - c->entries_len)
		return (NULL);
	slot = c->entries + c->entries_len;
	c->entries_len += n;
	return (slot);
}

/*
 * A chain step: running := H(CHAIN, running, child).  Every step hashes
 * exactly 33 bytes, so a chain's inputs determine its elements in order.
 */
static void
chain(uint8_t running[DIGEST], const uint8_t child[DIGEST])
{
	uint8_t input[1 + 2 * DIGEST], out[ERX_BLAKE3_OUT_LEN];

	input[0] = CANON_CHAIN;
	memcpy(input + 1, running, DIGEST);
	memcpy(input + 1 + DIGEST, child, DIGEST);
	(void)erx_blake3_hash_chunk(input, sizeof(input), out);
	memcpy(running, out, DIGEST);
}

static void
hash_begin(etf_check_t *c, uint8_t canon)
{
	erx_blake3_init(&c->hasher);
	erx_blake3_update(&c->hasher, &canon, 1);
}

static void
hash_u32(etf_check_t *c, uint32_t v)
{
	uint8_t be[4] = { (uint8_t)(v >> 24), (uint8_t)(v >> 16),
	    (uint8_t)(v >> 8), (uint8_t)v };

	erx_blake3_update(&c->hasher, be, sizeof(be));
}

static void
hash_end(etf_check_t *c, uint8_t digest[DIGEST])
{
	uint8_t out[ERX_BLAKE3_OUT_LEN];

	erx_blake3_final(&c->hasher, out);
	memcpy(digest, out, DIGEST);
}

/* An integer by its sign and its magnitude without high zero bytes. */
static void
digest_magnitude(etf_check_t *c, bool negative, const uint8_t *mag, size_t n,
    uint8_t digest[DIGEST])
{
	uint8_t sign;

	while (n > 0 && mag[n - 1] == 0)
		n--;
	sign = n > 0 && negative;
	hash_begin(c, CANON_INTEGER);
	erx_blake3_update(&c->hasher, &sign, 1);
	erx_blake3_update(&c->hasher, mag, n);
	hash_end(c, digest);
}

static void
digest_small(etf_check_t *c, int64_t v, uint8_t digest[DIGEST])
{
	uint8_t le[8];
	uint64_t mag;

	mag = v < 0 ? (uint64_t)(-(v + 1)) + 1 : (uint64_t)v;
	for (size_t i = 0; i < sizeof(le); i++)
		le[i] = (uint8_t)(mag >> (8 * i));
	digest_magnitude(c, v < 0, le, sizeof(le), digest);
}

static void
digest_node(etf_check_t *c, uint8_t canon, const uint8_t *node, size_t len)
{
	uint8_t n[2] = { (uint8_t)(len >> 8), (uint8_t)len };

	hash_begin(c, canon);
	erx_blake3_update(&c->hasher, n, sizeof(n));
	erx_blake3_update(&c->hasher, node, len);
}

/*
 * The digest of a leaf's canonical form.  A string is the list of its
 * bytes; a bitstring hashes its trailing-bit count and its bytes with the
 * unused low bits of the last one cleared, which ERTS ignores.
 */
static void
digest_leaf(etf_check_t *c, const erx_etf_item_t *item, uint8_t d[DIGEST])
{
	uint8_t bits[8], chained[DIGEST], last, tb;
	uint64_t raw;
	size_t n;

	switch (item->kind) {
	case ERX_ETF_INTEGER:
		digest_small(c, item->u.integer, d);
		return;
	case ERX_ETF_BIG:
		digest_magnitude(c, item->u.data.negative, item->u.data.bytes,
		    item->u.data.len, d);
		return;
	case ERX_ETF_FLOAT:
		memcpy(&raw, &item->u.real, sizeof(raw));
		for (size_t i = 0; i < sizeof(bits); i++)
			bits[i] = (uint8_t)(raw >> (56 - 8 * i));
		hash_begin(c, CANON_FLOAT);
		erx_blake3_update(&c->hasher, bits, sizeof(bits));
		break;
	case ERX_ETF_ATOM:
		hash_begin(c, CANON_ATOM);
		erx_blake3_update(&c->hasher, item->u.data.bytes,
		    item->u.data.len);
		break;
	case ERX_ETF_BINARY:
		n = item->u.data.len;
		tb = item->u.data.trailing_bits;
		hash_begin(c, CANON_BITS);
		erx_blake3_update(&c->hasher, &tb, 1);
		if (n > 0) {
			erx_blake3_update(&c->hasher, item->u.data.bytes, n - 1);
			last = item->u.data.bytes[n - 1] &
			    (uint8_t)(0xff << (8 - tb));
			erx_blake3_update(&c->hasher, &last, 1);
		}
		break;
	case ERX_ETF_PID:
		digest_node(c, CANON_PID, item->u.pid.node,
		    item->u.pid.node_len);
		hash_u32(c, item->u.pid.id);
		hash_u32(c, item->u.pid.serial);
		hash_u32(c, item->u.pid.creation);
		break;
	case ERX_ETF_REF:
		digest_node(c, CANON_REF, item->u.ref.node,
		    item->u.ref.node_len);
		hash_u32(c, item->u.ref.creation);
		for (size_t i = 0; i < ERX_ETF_REF_WORDS; i++)
			hash_u32(c, item->u.ref.words[i]);
		break;
	case ERX_ETF_STRING:
		digest_nil(c, d);
		if (item->u.data.len == 0)
			return;
		hash_begin(c, CANON_LIST);
		hash_end(c, chained);
		chain_bytes(c, chained, item->u.data.bytes, item->u.data.len);
		chain(chained, d);
		memcpy(d, chained, DIGEST);
		return;
	case ERX_ETF_NIL:
		digest_nil(c, d);
		return;
	case ERX_ETF_TUPLE:
		/* The empty tuple: the header a tuple's chain starts from. */
		hash_begin(c, CANON_TUPLE);
		hash_u32(c, 0);
		break;
	case ERX_ETF_MAP:
		/* The empty map: what a map with no pairs hashes. */
		hash_begin(c, CANON_MAP);
		hash_u32(c, 0);
		break;
	case ERX_ETF_LIST:
	case ERX_ETF_RECORD:
	case ERX_ETF_FUN:
	case ERX_ETF_EXPORT:
		/* Containers that always open a frame are never leaves. */
		hash_begin(c, CANON_CHAIN);
		break;
	}
	hash_end(c, d);
}

/* [], however it is written: NIL_EXT, an empty string, a list's end. */
static void
digest_nil(etf_check_t *c, uint8_t d[DIGEST])
{
	hash_begin(c, CANON_NIL);
	hash_end(c, d);
}

/* Chains the bytes of a string, each an integer element, onto running. */
static void
chain_bytes(etf_check_t *c, uint8_t running[DIGEST], const uint8_t *bytes,
    size_t len)
{
	uint8_t element[DIGEST];

	for (size_t i = 0; i < len; i++) {
		digest_small(c, bytes[i], element);
		chain(running, element);
	}
}

/*
 * The elements a container item's frame waits for: a list's tail counts
 * as one, a record's module and name and its field names and values, a
 * fun's module, old index, old uniq and creator and its free variables,
 * an export's module, function and arity.  A leaf has none.
 */
static uint64_t
frame_elements(const erx_etf_item_t *item)
{
	switch (item->kind) {
	case ERX_ETF_TUPLE:
		return (item->count);
	case ERX_ETF_LIST:
		return ((uint64_t)item->count + 1);
	case ERX_ETF_MAP:
		return (2 * (uint64_t)item->count);
	case ERX_ETF_RECORD:
		return (2 + 2 * (uint64_t)item->count);
	case ERX_ETF_FUN:
		return (4 + (uint64_t)item->count);
	case ERX_ETF_EXPORT:
		return (3);
	case ERX_ETF_INTEGER:
	case ERX_ETF_BIG:
	case ERX_ETF_FLOAT:
	case ERX_ETF_ATOM:
	case ERX_ETF_BINARY:
	case ERX_ETF_NIL:
	case ERX_ETF_STRING:
	case ERX_ETF_PID:
	case ERX_ETF_REF:
		break;
	}
	return (0);
}

/*
 * Pushes the frame of a container item.  A frame inside a key starts its
 * chain, when the check computes digests, with a digest of its kind and
 * header; a fun's header holds only the fields of its entry, not its old
 * index, old uniq or creator.  A map's digest is made whole when it ends,
 * from its sorted pairs.
 */
static void
frame_open(etf_check_t *c, etf_frame_t *f, const erx_etf_item_t *item,
    bool in_key)
{
	uint8_t arity;

	*f = (etf_frame_t){
		.kind = item->kind,
		.in_key = in_key,
		.count = item->count,
		.left = frame_elements(item),
		.base = c->entries_len,
	};
	if (!digesting(c, f))
		return;
	switch (item->kind) {
	case ERX_ETF_TUPLE:
		hash_begin(c, CANON_TUPLE);
		hash_u32(c, item->count);
		break;
	case ERX_ETF_LIST:
		hash_begin(c, CANON_LIST);
		break;
	case ERX_ETF_RECORD:
		hash_begin(c, item->u.exported ? CANON_RECORD_EXPORTED :
		    CANON_RECORD);
		hash_u32(c, item->count);
		break;
	case ERX_ETF_FUN:
		arity = item->u.fun.arity;
		hash_begin(c, CANON_FUN);
		erx_blake3_update(&c->hasher, &arity, 1);
		erx_blake3_update(&c->hasher, item->u.fun.uniq,
		    ERX_ETF_UNIQ_BYTES);
		hash_u32(c, item->u.fun.index);
		hash_u32(c, item->count);
		break;
	case ERX_ETF_EXPORT:
		hash_begin(c, CANON_EXPORT);
		break;
	case ERX_ETF_MAP:
	case ERX_ETF_INTEGER:
	case ERX_ETF_BIG:
	case ERX_ETF_FLOAT:
	case ERX_ETF_ATOM:
	case ERX_ETF_BINARY:
	case ERX_ETF_NIL:
	case ERX_ETF_STRING:
	case ERX_ETF_PID:
	case ERX_ETF_REF:
		return;
	}
	hash_end(c, f->chain);
}

static int
digest_cmp(const void *ctx ERX_UNUSED, const uint8_t *a, const uint8_t *b)
{
	return (memcmp(a, b, DIGEST));
}

/*
 * The text of the atom at offset off, which the tokenizer has read and
 * validated already, so its length and bytes lie inside the term.
 */
static const uint8_t *
atom_text_at(const uint8_t *term, uint32_t off, size_t *len)
{
	if (term[off] == TAG_SMALL_ATOM_UTF8) {
		*len = term[off + 1];
		return (term + off + 2);
	}
	*len = get_u16(term + off + 1);
	return (term + off + 3);
}

/* Two record field names by their text; an entry is the atom's offset. */
static int
atom_cmp(const void *ctx, const uint8_t *a, const uint8_t *b)
{
	const uint8_t *ta, *tb;
	uint32_t oa, ob;
	size_t la, lb;

	memcpy(&oa, a, sizeof(oa));
	memcpy(&ob, b, sizeof(ob));
	ta = atom_text_at(ctx, oa, &la);
	tb = atom_text_at(ctx, ob, &lb);
	if (la != lb)
		return (la < lb ? -1 : 1);
	return (memcmp(ta, tb, la));
}

/*
 * Heapsort of n entries of size bytes, in place and without recursion, so
 * the sort's stack and time stay bounded whatever the input.
 */
static void
sort_entries(uint8_t *base, size_t n, size_t size, etf_cmp_t cmp,
    const void *ctx)
{
	size_t child, end, root, start;
	uint8_t tmp;

	if (n < 2)
		return;
	for (start = n / 2, end = n;;) {
		if (start > 0) {
			start--;
		} else {
			end--;
			for (size_t i = 0; i < size; i++) {
				tmp = base[i];
				base[i] = base[end * size + i];
				base[end * size + i] = tmp;
			}
			if (end == 1)
				return;
		}
		for (root = start; (child = 2 * root + 1) < end; root = child) {
			if (child + 1 < end && cmp(ctx, base + child * size,
			    base + (child + 1) * size) < 0)
				child++;
			if (cmp(ctx, base + root * size, base + child * size) >= 0)
				break;
			for (size_t i = 0; i < size; i++) {
				tmp = base[root * size + i];
				base[root * size + i] = base[child * size + i];
				base[child * size + i] = tmp;
			}
		}
	}
}

static bool
has_equal_neighbours(const uint8_t *base, size_t n, size_t size, etf_cmp_t cmp,
    const void *ctx)
{
	for (size_t i = 1; i < n; i++) {
		if (cmp(ctx, base + (i - 1) * size, base + i * size) == 0)
			return (true);
	}
	return (false);
}

/* A record's field names, once the last is read: distinct, then dropped. */
static erx_etf_reason_t
check_names(etf_check_t *c, etf_frame_t *f)
{
	uint8_t *names;
	bool repeated;

	names = c->entries + f->base;
	sort_entries(names, f->count, sizeof(uint32_t), atom_cmp, c->term);
	repeated = has_equal_neighbours(names, f->count, sizeof(uint32_t),
	    atom_cmp, c->term);
	c->entries_len = f->base;
	return (repeated ? ERX_ETF_ERR_RECORD : ERX_ETF_OK);
}

/*
 * Map entries: a key digest, and beside it the value's digest when the
 * map computes its own digest, which hashes its pairs.
 */
static size_t
map_entry_size(const etf_check_t *c, const etf_frame_t *f)
{
	return (digesting(c, f) ? 2 * DIGEST : DIGEST);
}

/* A map's keys, once all are in: distinct under their digests. */
static erx_etf_reason_t
check_keys(etf_check_t *c, etf_frame_t *f)
{
	uint8_t *keys;
	size_t size;

	keys = c->entries + f->base;
	size = map_entry_size(c, f);
	sort_entries(keys, f->count, size, digest_cmp, NULL);
	return (has_equal_neighbours(keys, f->count, size, digest_cmp, NULL) ?
	    ERX_ETF_ERR_MAP_KEY : ERX_ETF_OK);
}

/*
 * Hands the digest d of the element of f that just ended to f.  Only an
 * element with a digest arrives here: any element of a frame that
 * computes a digest, and a map's key.  A frame computing a digest chains
 * d, except a fun's old index, old uniq and creator; a list's tail (the
 * element that ends while left is 0) ends the chain, or is the list's
 * digest when the list had no elements.  A map keeps each key's digest,
 * and its value's beside it when the map computes a digest.
 */
static erx_etf_reason_t
deliver(etf_check_t *c, etf_frame_t *f, const uint8_t d[DIGEST])
{
	uint32_t index;
	uint8_t *slot;

	index = f->next - 1;
	switch (f->kind) {
	case ERX_ETF_MAP:
		if (index % 2 == 1) {
			memcpy(c->entries + c->entries_len - DIGEST, d, DIGEST);
			return (ERX_ETF_OK);
		}
		slot = entry_push(c, map_entry_size(c, f));
		if (slot == NULL)
			return (ERX_ETF_ERR_SCRATCH);
		memcpy(slot, d, DIGEST);
		/*
		 * A map outside any key checks its keys as soon as the last
		 * key ends: its frame is dropped when its last value starts,
		 * so it never reaches finish.
		 */
		if (!digesting(c, f) && index == 2 * f->count - 2) {
			if (check_keys(c, f) != ERX_ETF_OK)
				return (ERX_ETF_ERR_MAP_KEY);
			c->entries_len = f->base;
		}
		return (ERX_ETF_OK);
	case ERX_ETF_LIST:
		if (f->left > 0) {
			chain(f->chain, d);
			f->elements++;
		} else if (f->elements == 0) {
			memcpy(f->chain, d, DIGEST);
		} else {
			chain(f->chain, d);
		}
		return (ERX_ETF_OK);
	case ERX_ETF_FUN:
		if (index == 0 || index >= 4)
			chain(f->chain, d);
		return (ERX_ETF_OK);
	case ERX_ETF_TUPLE:
	case ERX_ETF_RECORD:
	case ERX_ETF_EXPORT:
		chain(f->chain, d);
		return (ERX_ETF_OK);
	case ERX_ETF_INTEGER:
	case ERX_ETF_BIG:
	case ERX_ETF_FLOAT:
	case ERX_ETF_ATOM:
	case ERX_ETF_BINARY:
	case ERX_ETF_NIL:
	case ERX_ETF_STRING:
	case ERX_ETF_PID:
	case ERX_ETF_REF:
		break;
	}
	/* A leaf never has a frame. */
	return (ERX_ETF_ERR_TAG);
}

/*
 * Completes f, all of whose elements have ended.  A frame computing a
 * digest leaves it in d: a map checks its keys and hashes its pairs in
 * key-digest order, any other frame hands over its chain.
 */
static erx_etf_reason_t
finish(etf_check_t *c, etf_frame_t *f, uint8_t d[DIGEST])
{
	if (!digesting(c, f))
		return (ERX_ETF_OK);
	if (f->kind != ERX_ETF_MAP) {
		memcpy(d, f->chain, DIGEST);
		return (ERX_ETF_OK);
	}
	if (check_keys(c, f) != ERX_ETF_OK)
		return (ERX_ETF_ERR_MAP_KEY);
	hash_begin(c, CANON_MAP);
	hash_u32(c, f->count);
	erx_blake3_update(&c->hasher, c->entries + f->base,
	    (size_t)f->count * 2 * DIGEST);
	hash_end(c, d);
	c->entries_len = f->base;
	return (ERX_ETF_OK);
}

/*
 * An element of the top frame has ended, with digest d when digested.
 * Hands it up, and completes every frame whose last element this was,
 * handing each one's digest to the frame below.
 */
static erx_etf_reason_t
ended(etf_check_t *c, bool digested, const uint8_t d[DIGEST])
{
	erx_etf_reason_t reason;
	uint8_t digest[DIGEST];
	etf_frame_t *f;

	memcpy(digest, d, DIGEST);
	while (c->depth > 0) {
		f = &c->frames[c->depth - 1];
		if (digested) {
			reason = deliver(c, f, digest);
			if (reason != ERX_ETF_OK)
				return (reason);
		}
		if (f->left > 0)
			return (ERX_ETF_OK);
		reason = finish(c, f, digest);
		if (reason != ERX_ETF_OK)
			return (reason);
		digested = digesting(c, f);
		c->depth--;
	}
	return (ERX_ETF_OK);
}

static erx_etf_verdict_t
verdict_of(erx_etf_reason_t reason)
{
	switch (reason) {
	case ERX_ETF_OK:
		return (ERX_ETF_ACCEPTED);
	case ERX_ETF_ERR_DEPTH:
	case ERX_ETF_ERR_WORDS:
	case ERX_ETF_ERR_SCRATCH:
	case ERX_ETF_ERR_TOO_LONG:
		return (ERX_ETF_OVER_LIMIT);
	default:
		return (ERX_ETF_MALFORMED);
	}
}

/*
 * The frames a term of len bytes, its version byte among them, can have
 * open at once: never more than max_depth, and at most len / 2.  Every
 * container takes at least two bytes before its first element
 * (SMALL_TUPLE_EXT) but an export (EXPORT_EXT), which takes one; an export
 * holds only leaves, so it is only ever the top frame, and the version
 * byte, which is no item, pays for its missing byte.
 */
static size_t
frames_for(const erx_etf_rules_t *rules, size_t len)
{
	return (len / 2 < rules->max_depth ? len / 2 : rules->max_depth);
}

/*
 * Entry-stack bytes a byte of the term can make the check keep, charged
 * to the items they are kept for; every item takes at least one byte.
 * Without accept, only a record's field names are kept, 4 bytes each, and
 * a name is an atom of at least two bytes: 2 bytes a byte.  With accept,
 * also a map's keys: a pair keeps at most 32 bytes, a key digest and, in a
 * map inside a key, its value's beside it, and takes two items, its key
 * and its value, which belong to no other pair or record: 16 bytes an
 * item.  Only the pair whose key ended last can be waiting for its value,
 * since the next item read starts that value; its other 16 bytes are
 * charged to the version byte, a budget apart from the frames' own.  So
 * 16 bytes a byte.
 */
#define ENTRY_BYTES_PER_BYTE		2
#define ENTRY_BYTES_PER_BYTE_ACCEPT	16

/* The frames and entries a term of len bytes can take, and the padding. */
size_t
erx_etf_scratch_bytes(const erx_etf_rules_t *rules, size_t len)
{
	size_t entries, frames, total;

	if (__builtin_mul_overflow(frames_for(rules, len), sizeof(etf_frame_t),
	    &frames) ||
	    __builtin_mul_overflow(len, (size_t)(rules->accept ?
	    ENTRY_BYTES_PER_BYTE_ACCEPT : ENTRY_BYTES_PER_BYTE), &entries) ||
	    __builtin_add_overflow(frames, entries, &total) ||
	    __builtin_add_overflow(total, _Alignof(etf_frame_t), &total))
		return (SIZE_MAX);
	return (total);
}

/*
 * The check's loop takes one item at a time.  The item starts an element
 * of the top frame, or is the whole term when no frame is open.  A list's
 * tail that is itself a LIST_EXT or STRING_EXT continues the same list.  A
 * container pushes a frame, after dropping the top frame if this is its
 * last element and the frame is outside any map key, since nothing
 * remains for it to do.  A leaf ends at once, and so may every frame it
 * completes.
 */
erx_etf_verdict_t
erx_etf_check(const uint8_t *term, size_t len, const erx_etf_rules_t *rules,
    void *scratch, size_t scratch_len, erx_etf_result_t *result)
{
	etf_check_t c;
	etf_frame_t *f;
	etf_token_t t;
	erx_etf_reason_t reason;
	uint8_t d[DIGEST] = { 0 }, nil[DIGEST];
	size_t frames_bytes, offset, pad, pos;
	uint32_t index;
	bool digested, in_key;

	*result = (erx_etf_result_t){ .verdict = ERX_ETF_MALFORMED };
	c = (etf_check_t){ .rules = rules, .term = term, .len = len };
	offset = 0;
	pos = 0;
	reason = ERX_ETF_OK;
	pad = (size_t)(-(uintptr_t)scratch & (_Alignof(etf_frame_t) - 1));
	if (len > ERX_ETF_INPUT_MAX) {
		reason = ERX_ETF_ERR_TOO_LONG;
		goto done;
	}
	if (len == 0 || term[0] != ERX_ETF_VERSION) {
		reason = ERX_ETF_ERR_VERSION_BYTE;
		goto done;
	}
	c.frames_cap = frames_for(rules, len);
	if (__builtin_mul_overflow(c.frames_cap, sizeof(etf_frame_t),
	    &frames_bytes) || pad > scratch_len ||
	    frames_bytes > scratch_len - pad) {
		reason = ERX_ETF_ERR_SCRATCH;
		goto done;
	}
	c.frames = (etf_frame_t *)((uint8_t *)scratch + pad);
	c.entries = (uint8_t *)scratch + pad + frames_bytes;
	c.entries_cap = scratch_len - pad - frames_bytes;
	digest_nil(&c, nil);

	pos = 1;
	do {
		offset = pos;
		reason = token(term, len, &pos, &t);
		if (reason != ERX_ETF_OK)
			goto done;
		f = c.depth > 0 ? &c.frames[c.depth - 1] : NULL;
		index = 0;
		if (f != NULL) {
			index = f->next++;
			f->left--;
		}
		reason = admit(&c, f, index, &t);
		if (reason == ERX_ETF_OK && f != NULL)
			reason = note_field_name(&c, f, index, offset);
		if (reason != ERX_ETF_OK)
			goto done;

		/* A list continued by its tail. */
		if (f != NULL && f->kind == ERX_ETF_LIST && f->left == 0) {
			if (t.item.kind == ERX_ETF_LIST) {
				f->left = (uint64_t)t.item.count + 1;
				continue;
			}
			if (t.item.kind == ERX_ETF_STRING) {
				if (digesting(&c, f) && t.item.u.data.len > 0) {
					chain_bytes(&c, f->chain,
					    t.item.u.data.bytes,
					    t.item.u.data.len);
					f->elements += t.item.u.data.len;
				}
				reason = ended(&c, digesting(&c, f), nil);
				if (reason != ERX_ETF_OK)
					goto done;
				continue;
			}
		}

		in_key = f != NULL && (f->in_key ||
		    (f->kind == ERX_ETF_MAP && index % 2 == 0));
		digested = rules->accept && in_key;
		if (opens_frame(&t.item)) {
			if (f != NULL && f->left == 0 && !f->in_key)
				c.depth--;
			if (c.depth >= rules->max_depth) {
				reason = ERX_ETF_ERR_DEPTH;
				goto done;
			}
			/*
			 * Never, while frames_for is right; were it wrong, the
			 * term would be over a limit, never written past the stack.
			 */
			if (c.depth >= c.frames_cap) {
				reason = ERX_ETF_ERR_SCRATCH;
				goto done;
			}
			frame_open(&c, &c.frames[c.depth], &t.item, in_key);
			c.depth++;
			continue;
		}
		if (digested)
			digest_leaf(&c, &t.item, d);
		reason = ended(&c, digested, d);
		if (reason != ERX_ETF_OK)
			goto done;
	} while (c.depth > 0);
	offset = pos;
	if (pos != len)
		reason = ERX_ETF_ERR_TRAILING;

done:
	result->verdict = verdict_of(reason);
	result->reason = reason;
	result->offset = reason == ERX_ETF_OK ? len : offset;
	result->words = c.words;
	return (result->verdict);
}

bool
erx_etf_reader_init(erx_etf_reader_t *reader, const uint8_t *term, size_t len)
{
	*reader = (erx_etf_reader_t){ .bytes = term, .len = len, .pos = 1 };
	return (len > 0 && term[0] == ERX_ETF_VERSION);
}

erx_etf_step_t
erx_etf_next(erx_etf_reader_t *reader, erx_etf_item_t *item,
    erx_etf_reason_t *reason)
{
	etf_token_t t;

	*reason = ERX_ETF_OK;
	if (reader->pos >= reader->len)
		return (ERX_ETF_STEP_END);
	*reason = token(reader->bytes, reader->len, &reader->pos, &t);
	if (*reason != ERX_ETF_OK)
		return (ERX_ETF_STEP_ERROR);
	*item = t.item;
	return (ERX_ETF_STEP_ITEM);
}

/*
 * The writer.  A call whose arguments no term can hold, or that finds no
 * room, marks the writer failed; a failed writer appends nothing more, and
 * erx_etf_writer_done reports the failure, so a caller checks once at the
 * end.  A call may leave part of an item behind it when it fails.
 */
static void
writer_fail(erx_etf_writer_t *w)
{
	w->failed = true;
}

/* Reserves head + tail bytes, or NULL after marking the writer failed. */
static uint8_t *
put(erx_etf_writer_t *w, size_t head, size_t tail)
{
	uint8_t *p;
	size_t n;

	if (w->failed || __builtin_add_overflow(head, tail, &n) ||
	    n > w->cap - w->len) {
		writer_fail(w);
		return (NULL);
	}
	p = w->buf + w->len;
	w->len += n;
	return (p);
}

/* Copies a caller's bytes, which may be NULL when there are none. */
static void
put_bytes(uint8_t *p, const void *bytes, size_t len)
{
	if (len > 0)
		memcpy(p, bytes, len);
}

static void
put_u16(uint8_t *p, uint16_t v)
{
	p[0] = (uint8_t)(v >> 8);
	p[1] = (uint8_t)v;
}

static void
put_u32(uint8_t *p, uint32_t v)
{
	p[0] = (uint8_t)(v >> 24);
	p[1] = (uint8_t)(v >> 16);
	p[2] = (uint8_t)(v >> 8);
	p[3] = (uint8_t)v;
}

static void
put_tag(erx_etf_writer_t *w, uint8_t tag)
{
	uint8_t *p;

	p = put(w, 1, 0);
	if (p != NULL)
		p[0] = tag;
}

static void
put_tagged_u32(erx_etf_writer_t *w, uint8_t tag, uint32_t v)
{
	uint8_t *p;

	p = put(w, 5, 0);
	if (p == NULL)
		return;
	p[0] = tag;
	put_u32(p + 1, v);
}

void
erx_etf_writer_init(erx_etf_writer_t *writer, uint8_t *buf, size_t cap)
{
	*writer = (erx_etf_writer_t){ .buf = buf, .cap = cap };
	put_tag(writer, ERX_ETF_VERSION);
}

bool
erx_etf_writer_done(const erx_etf_writer_t *writer, size_t *len)
{
	*len = writer->failed ? 0 : writer->len;
	return (!writer->failed);
}

void
erx_etf_put_atom(erx_etf_writer_t *w, const char *name, size_t len)
{
	uint8_t *p;

	if (!atom_text_ok((const uint8_t *)name, len)) {
		writer_fail(w);
		return;
	}
	if (len <= UINT8_MAX) {
		p = put(w, 2, len);
		if (p == NULL)
			return;
		p[0] = TAG_SMALL_ATOM_UTF8;
		p[1] = (uint8_t)len;
		put_bytes(p + 2, name, len);
	} else {
		p = put(w, 3, len);
		if (p == NULL)
			return;
		p[0] = TAG_ATOM_UTF8;
		put_u16(p + 1, (uint16_t)len);
		put_bytes(p + 3, name, len);
	}
}

void
erx_etf_put_big(erx_etf_writer_t *w, bool negative, const uint8_t *mag,
    size_t len)
{
	uint8_t *p;

	if (len > ERX_ETF_BIG_BYTES_MAX) {
		writer_fail(w);
		return;
	}
	if (len <= UINT8_MAX) {
		p = put(w, 3, len);
		if (p == NULL)
			return;
		p[0] = TAG_SMALL_BIG;
		p[1] = (uint8_t)len;
		p[2] = negative;
		put_bytes(p + 3, mag, len);
	} else {
		p = put(w, 6, len);
		if (p == NULL)
			return;
		p[0] = TAG_LARGE_BIG;
		put_u32(p + 1, (uint32_t)len);
		p[5] = negative;
		put_bytes(p + 6, mag, len);
	}
}

void
erx_etf_put_binary(erx_etf_writer_t *w, const void *bytes, size_t len)
{
	uint8_t *p;

	if (len > UINT32_MAX) {
		writer_fail(w);
		return;
	}
	p = put(w, 5, len);
	if (p == NULL)
		return;
	p[0] = TAG_BINARY;
	put_u32(p + 1, (uint32_t)len);
	put_bytes(p + 5, bytes, len);
}

void
erx_etf_put_bits(erx_etf_writer_t *w, const void *bytes, size_t len,
    unsigned trailing_bits)
{
	uint8_t *p;

	if (len == 0 || len > UINT32_MAX || trailing_bits < 1 ||
	    trailing_bits > 8) {
		writer_fail(w);
		return;
	}
	p = put(w, 6, len);
	if (p == NULL)
		return;
	p[0] = TAG_BIT_BINARY;
	put_u32(p + 1, (uint32_t)len);
	p[5] = (uint8_t)trailing_bits;
	put_bytes(p + 6, bytes, len);
}

void
erx_etf_put_export(erx_etf_writer_t *w)
{
	put_tag(w, TAG_EXPORT);
}

void
erx_etf_put_float(erx_etf_writer_t *w, double value)
{
	uint64_t bits;
	uint8_t *p;

	memcpy(&bits, &value, sizeof(bits));
	if ((bits >> 52 & 0x7ff) == 0x7ff) {
		writer_fail(w);
		return;
	}
	p = put(w, 9, 0);
	if (p == NULL)
		return;
	p[0] = TAG_NEW_FLOAT;
	put_u32(p + 1, (uint32_t)(bits >> 32));
	put_u32(p + 5, (uint32_t)bits);
}

/*
 * The fun's header.  Its Size field, the encoding's length, is written as
 * 0: the caller writes the fields after it, and ERTS's decoder ignores it.
 */
void
erx_etf_put_fun(erx_etf_writer_t *w, const erx_etf_fun_t *fun,
    uint32_t free_count)
{
	uint8_t *p;

	if (free_count > ERX_ETF_FUN_FREE_MAX) {
		writer_fail(w);
		return;
	}
	p = put(w, 30, 0);
	if (p == NULL)
		return;
	p[0] = TAG_NEW_FUN;
	put_u32(p + 1, 0);
	p[5] = fun->arity;
	memcpy(p + 6, fun->uniq, ERX_ETF_UNIQ_BYTES);
	put_u32(p + 22, fun->index);
	put_u32(p + 26, free_count);
}

void
erx_etf_put_integer(erx_etf_writer_t *w, int64_t value)
{
	uint8_t mag[8], *p;
	uint64_t m;
	size_t n;

	if (value >= 0 && value <= UINT8_MAX) {
		p = put(w, 2, 0);
		if (p == NULL)
			return;
		p[0] = TAG_SMALL_INTEGER;
		p[1] = (uint8_t)value;
	} else if (value >= INT32_MIN && value <= INT32_MAX) {
		put_tagged_u32(w, TAG_INTEGER, (uint32_t)(int32_t)value);
	} else {
		/* As term_to_binary: SMALL_BIG_EXT, no high zero bytes. */
		m = value < 0 ? (uint64_t)(-(value + 1)) + 1 : (uint64_t)value;
		for (n = 0; n < sizeof(mag) && m >> (8 * n) != 0; n++)
			mag[n] = (uint8_t)(m >> (8 * n));
		erx_etf_put_big(w, value < 0, mag, n);
	}
}

void
erx_etf_put_list(erx_etf_writer_t *w, uint32_t count)
{
	put_tagged_u32(w, TAG_LIST, count);
}

void
erx_etf_put_map(erx_etf_writer_t *w, uint32_t pairs)
{
	if (pairs >> 31 != 0) {
		writer_fail(w);
		return;
	}
	put_tagged_u32(w, TAG_MAP, pairs);
}

void
erx_etf_put_nil(erx_etf_writer_t *w)
{
	put_tag(w, TAG_NIL);
}

void
erx_etf_put_pid(erx_etf_writer_t *w, const erx_etf_pid_t *pid)
{
	uint8_t *p;

	put_tag(w, TAG_NEW_PID);
	erx_etf_put_atom(w, (const char *)pid->node, pid->node_len);
	p = put(w, 12, 0);
	if (p == NULL)
		return;
	put_u32(p, pid->id);
	put_u32(p + 4, pid->serial);
	put_u32(p + 8, pid->creation);
}

void
erx_etf_put_record(erx_etf_writer_t *w, uint32_t fields, bool exported)
{
	uint8_t *p;

	if (fields > ERX_ETF_RECORD_FIELDS_MAX) {
		writer_fail(w);
		return;
	}
	p = put(w, 6, 0);
	if (p == NULL)
		return;
	p[0] = TAG_RECORD;
	put_u32(p + 1, fields);
	p[5] = exported;
}

void
erx_etf_put_ref(erx_etf_writer_t *w, const erx_etf_ref_t *ref)
{
	uint8_t *p;

	p = put(w, 3, 0);
	if (p == NULL)
		return;
	p[0] = TAG_NEWER_REFERENCE;
	put_u16(p + 1, ERX_ETF_REF_WORDS);
	erx_etf_put_atom(w, (const char *)ref->node, ref->node_len);
	p = put(w, 4 + 4 * ERX_ETF_REF_WORDS, 0);
	if (p == NULL)
		return;
	put_u32(p, ref->creation);
	for (size_t i = 0; i < ERX_ETF_REF_WORDS; i++)
		put_u32(p + 4 + 4 * i, ref->words[i]);
}

void
erx_etf_put_string(erx_etf_writer_t *w, const uint8_t *bytes, size_t len)
{
	uint8_t *p;

	if (len > UINT16_MAX) {
		writer_fail(w);
		return;
	}
	p = put(w, 3, len);
	if (p == NULL)
		return;
	p[0] = TAG_STRING;
	put_u16(p + 1, (uint16_t)len);
	put_bytes(p + 3, bytes, len);
}

void
erx_etf_put_tuple(erx_etf_writer_t *w, uint32_t arity)
{
	uint8_t *p;

	if (arity > ERX_ETF_TUPLE_ARITY_MAX) {
		writer_fail(w);
	} else if (arity <= UINT8_MAX) {
		p = put(w, 2, 0);
		if (p == NULL)
			return;
		p[0] = TAG_SMALL_TUPLE;
		p[1] = (uint8_t)arity;
	} else {
		put_tagged_u32(w, TAG_LARGE_TUPLE, arity);
	}
}
