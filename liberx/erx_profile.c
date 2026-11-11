/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

/*
 * The interpreter of frame profile tables (erx/profile.h).  One walker
 * serves both the check and a list view's next: begin() reads one term
 * of a kind, judging a scalar on the spot or pushing a level for a
 * container, and step() advances the top level by one child or pops it.
 * The check runs it with the frame-wide rules counted (the sums of each
 * total, the values of the unique kind, the two bitmaps of each refers),
 * a view's next without them, since the frame was accepted whole.  No
 * function calls itself or another that calls it back: the stack is
 * the walk's own array.
 */

#include <stdint.h>
#include <string.h>

#include <erx/etf.h>
#include <erx/profile.h>

/* A key of an ascending list: an integer, or an atom's bytes. */
typedef struct key {
	const uint8_t		*atom;
	size_t			 len;
	uint64_t		 integer;
	bool			 is_atom;
	bool			 valid;
} key_t;

/*
 * One container being read.  index counts the elements started (a tuple's
 * or a union tuple's) or the pairs left (a map's); a list counts its
 * elements in count and reads its current segment through segment_left or
 * string; seen is a map's keys seen or a union's remaining candidates.
 */
typedef struct level {
	const erx_profile_kind_t *k;
	uint8_t			*store;
	const uint8_t		*string;
	key_t			 key;
	uint64_t		 seen;
	uint32_t		 index;
	uint32_t		 arity;
	uint32_t		 count;
	uint32_t		 segment_left;
	uint32_t		 string_left;
	uint16_t		 kind;
	bool			 in_string;
	bool			 held_refers;
} level_t;

typedef struct walk {
	const erx_profile_t	*p;
	erx_profile_refusal_t	*refusal;
	uint64_t		*uniq;
	uint8_t			*bitmaps;
	erx_etf_reader_t	 rd;
	level_t			 stack[ERX_PROFILE_DEPTH_MAX];
	uint64_t		 sums[ERX_PROFILE_TOTALS_MAX];
	key_t			 done_key;	/* the key of the value just read */
	size_t			 nuniq;
	size_t			 uniq_cap;
	size_t			 item;		/* offset of the item being read */
	unsigned		 top;
	bool			 global;	/* count the frame-wide rules */
} walk_t;

static bool	begin(walk_t *, uint16_t, uint8_t *);
static size_t	bitmap_size(const erx_profile_refers_t *);

static const char *const reason_names[] = {
	[ERX_PROFILE_OK] = "ok", [ERX_PROFILE_SIZE] = "size",
	[ERX_PROFILE_SHAPE] = "shape", [ERX_PROFILE_VERSION] = "version",
	[ERX_PROFILE_RANGE] = "range", [ERX_PROFILE_LENGTH] = "length",
	[ERX_PROFILE_UTF8] = "utf8", [ERX_PROFILE_TEXT] = "text",
	[ERX_PROFILE_KEY] = "key", [ERX_PROFILE_NO_CASE] = "no_case",
	[ERX_PROFILE_ORDER] = "order", [ERX_PROFILE_UNIQUE] = "unique",
	[ERX_PROFILE_REFERS] = "refers", [ERX_PROFILE_TOTAL] = "total",
	[ERX_PROFILE_MALFORMED] = "malformed", [ERX_PROFILE_SCRATCH] = "scratch",
};

const char *
erx_profile_reason_name(erx_profile_reason_t reason)
{
	if ((size_t)reason >= sizeof(reason_names) / sizeof(reason_names[0]))
		return ("unknown");
	return (reason_names[reason]);
}

const char *
erx_profile_name(const erx_profile_t *p, uint16_t name)
{
	return (name < p->nnames ? p->names[name] : "unknown");
}

static bool
refuse(walk_t *w, erx_profile_reason_t reason, uint16_t kind)
{
	*w->refusal = (erx_profile_refusal_t){ .offset = w->item,
	    .reason = reason, .kind = kind };
	return (false);
}

static bool
atom_is(const erx_etf_item_t *item, const char *name)
{
	size_t n;

	n = strlen(name);
	return (item->kind == ERX_ETF_ATOM && item->u.data.len == n &&
	    memcmp(item->u.data.bytes, name, n) == 0);
}

/*
 * The next term's first item.  A LIST_EXT of no element is its tail, so
 * the loop takes the item after it in its place.  Bytes that are no item,
 * or none at all, are malformed, refused as of kind.
 */
static bool
read_term(walk_t *w, erx_etf_item_t *item, uint16_t kind)
{
	erx_etf_reason_t reason;

	for (;;) {
		w->item = w->rd.pos;
		if (erx_etf_next(&w->rd, item, &reason) != ERX_ETF_STEP_ITEM)
			return (refuse(w, ERX_PROFILE_MALFORMED, kind));
		if (item->kind != ERX_ETF_LIST || item->count != 0)
			return (true);
	}
}

static void
store_value(uint8_t *store, const void *value, size_t size)
{
	if (store != NULL)
		memcpy(store, value, size);
}

static void
store_integer(uint8_t *store, uint64_t v, uint16_t size)
{
	uint8_t v8;
	uint16_t v16;
	uint32_t v32;

	switch (size) {
	case 1:
		v8 = (uint8_t)v;
		store_value(store, &v8, 1);
		break;
	case 2:
		v16 = (uint16_t)v;
		store_value(store, &v16, 2);
		break;
	case 4:
		v32 = (uint32_t)v;
		store_value(store, &v32, 4);
		break;
	default:
		store_value(store, &v, 8);
		break;
	}
}

/* An integer item's value as a u64: false for a negative or wider one. */
static bool
item_u64(const erx_etf_item_t *item, uint64_t *v)
{
	size_t i, n;

	if (item->kind == ERX_ETF_INTEGER) {
		if (item->u.integer < 0)
			return (false);
		*v = (uint64_t)item->u.integer;
		return (true);
	}
	/* A big item holds a value no int64_t holds: past 2^63 - 1, or below. */
	if (item->u.data.negative)
		return (false);
	n = item->u.data.len;
	while (n > 0 && item->u.data.bytes[n - 1] == 0)
		n--;
	if (n > 8)
		return (false);
	*v = 0;
	for (i = n; i > 0; i--)
		*v = *v << 8 | item->u.data.bytes[i - 1];
	return (true);
}

/* RFC 3629: no overlong form, surrogate or code point past 0x10ffff. */
static bool
valid_utf8(const uint8_t *b, size_t len)
{
	size_t i, n, k;
	uint32_t c, min;

	for (i = 0; i < len; i += n) {
		c = b[i];
		if (c < 0x80) {
			n = 1;
			continue;
		}
		if (c >= 0xc2 && c <= 0xdf) {
			n = 2;
			c &= 0x1f;
			min = 0x80;
		} else if (c >= 0xe0 && c <= 0xef) {
			n = 3;
			c &= 0x0f;
			min = 0x800;
		} else if (c >= 0xf0 && c <= 0xf4) {
			n = 4;
			c &= 0x07;
			min = 0x10000;
		} else
			return (false);
		if (n > len - i)
			return (false);
		for (k = 1; k < n; k++) {
			if ((b[i + k] & 0xc0) != 0x80)
				return (false);
			c = c << 6 | (b[i + k] & 0x3fu);
		}
		if (c < min || c > 0x10ffff || (c >= 0xd800 && c <= 0xdfff))
			return (false);
	}
	return (true);
}

/* A leading /, no empty, . or .. component, and a trailing / only in /. */
static bool
valid_path(const uint8_t *b, size_t len)
{
	size_t start, end;

	if (len == 0 || b[0] != '/')
		return (false);
	if (len == 1)
		return (true);
	for (start = 1; start <= len; start = end + 1) {
		end = start;
		while (end < len && b[end] != '/')
			end++;
		if (end == start)
			return (false);
		if (b[start] == '.' && (end - start == 1 ||
		    (end - start == 2 && b[start + 1] == '.')))
			return (false);
	}
	return (true);
}

/* Refers rule r's bitmap of the values referred to; its targets follow it. */
static uint8_t *
referred_bitmap(walk_t *w, uint16_t r)
{
	uint8_t *b;
	uint16_t i;

	b = w->bitmaps;
	for (i = 0; i < r; i++)
		b += 2 * bitmap_size(&w->p->refers[i]);
	return (b);
}

static level_t *
parent(walk_t *w)
{
	return (w->top > 0 ? &w->stack[w->top - 1] : NULL);
}

static int
key_compare(const key_t *a, const key_t *b)
{
	size_t n;
	int c;

	if (!a->is_atom)
		return (a->integer < b->integer ? -1 : a->integer > b->integer);
	n = a->len < b->len ? a->len : b->len;
	c = n == 0 ? 0 : memcmp(a->atom, b->atom, n);
	if (c != 0)
		return (c);
	return (a->len < b->len ? -1 : a->len > b->len);
}

/*
 * The value just read (its key in w->done_key) is done: its container
 * takes note.  A tuple keeps its first field's key; a list holds each
 * element's key above the last when ascending, and an element of a refers
 * target that took no refers value becomes a key a reference may name.
 */
static bool
complete(walk_t *w)
{
	const erx_profile_refers_t *r;
	level_t *l;
	uint64_t bit;

	l = parent(w);
	if (l == NULL)
		return (true);
	if (l->k->form == ERX_PROFILE_TUPLE && l->index == 1)
		l->key = w->done_key;
	if (l->k->form != ERX_PROFILE_LIST)
		return (true);
	if (l->k->ascending) {
		if (l->key.valid && key_compare(&l->key, &w->done_key) >= 0)
			return (refuse(w, ERX_PROFILE_ORDER, l->kind));
		l->key = w->done_key;
	}
	if (w->global && l->k->target != ERX_PROFILE_NONE && !l->held_refers &&
	    w->done_key.valid && !w->done_key.is_atom) {
		r = &w->p->refers[l->k->target];
		if (w->done_key.integer >= r->low &&
		    w->done_key.integer - r->low < r->range) {
			bit = w->done_key.integer - r->low;
			referred_bitmap(w, l->k->target)[bitmap_size(r) +
			    bit / 8] |= (uint8_t)(1u << (bit % 8));
		}
	}
	return (true);
}

static bool
push(walk_t *w, uint16_t kind, uint8_t *store, level_t **out)
{
	const erx_profile_kind_t *k;

	k = &w->p->kinds[kind];
	if (w->top >= ERX_PROFILE_DEPTH_MAX)
		return (refuse(w, ERX_PROFILE_MALFORMED, kind));
	*out = &w->stack[w->top++];
	**out = (level_t){ .k = k, .kind = kind, .store = store };
	if (store != NULL && k->form != ERX_PROFILE_LIST)
		memset(store, 0, k->size);
	return (true);
}

/* Counts what the frame-wide rules need of an integer of kind k. */
static bool
count_integer(walk_t *w, const erx_profile_kind_t *k, uint16_t kind, uint64_t v)
{
	const erx_profile_refers_t *r;
	uint64_t bit;
	unsigned i;

	if (!w->global)
		return (true);
	if (k->unique) {
		if (w->nuniq == w->uniq_cap)
			return (refuse(w, ERX_PROFILE_SCRATCH, kind));
		w->uniq[w->nuniq++] = v;
	}
	if (k->refers == ERX_PROFILE_NONE)
		return (true);
	r = &w->p->refers[k->refers];
	/* The generator holds a refers kind's range within its list's keys. */
	if (v < r->low || v - r->low >= r->range)
		return (refuse(w, ERX_PROFILE_REFERS, kind));
	bit = v - r->low;
	referred_bitmap(w, k->refers)[bit / 8] |= (uint8_t)(1u << (bit % 8));
	for (i = w->top; i > 0; i--) {
		if (w->stack[i - 1].kind == r->list) {
			w->stack[i - 1].held_refers = true;
			break;
		}
	}
	return (true);
}

static bool
judge_integer(walk_t *w, uint16_t kind, uint64_t v, uint8_t *store)
{
	const erx_profile_kind_t *k;
	bool in;
	uint16_t i;

	k = &w->p->kinds[kind];
	in = v >= k->min && v <= k->max;
	if (k->nvalues != 0) {
		in = false;
		for (i = 0; i < k->nvalues; i++)
			in = in || v == k->values[i];
	}
	if (!in || (k->has_except && v == k->except))
		return (refuse(w, ERX_PROFILE_RANGE, kind));
	if (!count_integer(w, k, kind, v))
		return (false);
	store_integer(store, v, k->size);
	w->done_key = (key_t){ .integer = v, .valid = true };
	return (complete(w));
}

static bool
judge_text(walk_t *w, uint16_t kind, const erx_etf_item_t *item, uint8_t *store)
{
	const erx_profile_kind_t *k;
	const uint8_t *b, *eq;
	erx_profile_text_t text;
	size_t len;

	k = &w->p->kinds[kind];
	if (item->kind != ERX_ETF_BINARY || item->u.data.trailing_bits != 8)
		return (refuse(w, ERX_PROFILE_SHAPE, kind));
	b = item->u.data.bytes;
	len = item->u.data.len;
	if (len > k->text_max)
		return (refuse(w, ERX_PROFILE_LENGTH, kind));
	if ((k->rules & ERX_PROFILE_UTF8_RULE) && !valid_utf8(b, len))
		return (refuse(w, ERX_PROFILE_UTF8, kind));
	if ((k->rules & ERX_PROFILE_NUL_RULE) && len > 0 &&
	    memchr(b, 0, len) != NULL)
		return (refuse(w, ERX_PROFILE_TEXT, kind));
	if (k->rules & ERX_PROFILE_ASSIGN_RULE) {
		eq = len > 0 ? memchr(b, '=', len) : NULL;
		if (eq == NULL || eq == b)
			return (refuse(w, ERX_PROFILE_TEXT, kind));
	}
	if ((k->rules & ERX_PROFILE_PATH_RULE) && !valid_path(b, len))
		return (refuse(w, ERX_PROFILE_TEXT, kind));
	/* len is at most text_max, a u32, so the sum of a frame's texts cannot wrap. */
	if (w->global && k->sum != ERX_PROFILE_NONE)
		w->sums[k->sum] += (uint64_t)len + 1;
	text = (erx_profile_text_t){ .bytes = b, .len = len };
	store_value(store, &text, sizeof(text));
	w->done_key = (key_t){ .valid = false };
	return (complete(w));
}

/* An atom selecting a union's case without fields. */
static bool
judge_atom_case(walk_t *w, uint16_t kind, const erx_etf_item_t *item,
    uint8_t *store)
{
	const erx_profile_kind_t *k;
	uint16_t c;

	k = &w->p->kinds[kind];
	for (c = 0; c < k->ncases; c++) {
		if (k->cases[c].nfields == 0 && atom_is(item, k->cases[c].atoms[0]))
			break;
	}
	if (c == k->ncases)
		return (refuse(w, ERX_PROFILE_NO_CASE, kind));
	if (store != NULL && k->form == ERX_PROFILE_UNION)
		memset(store, 0, k->size);
	store_value(store, &c, sizeof(c));
	w->done_key = (key_t){ .atom = item->u.data.bytes,
	    .len = item->u.data.len, .is_atom = true, .valid = true };
	return (complete(w));
}

/* Starts a list whose first item is item; a view of it goes to store. */
static bool
begin_list(walk_t *w, uint16_t kind, const erx_etf_item_t *item, uint8_t *store)
{
	erx_profile_list_t view;
	level_t *l;

	view = (erx_profile_list_t){ .profile = w->p, .frame = w->rd.bytes,
	    .len = w->rd.len, .pos = w->rd.pos,
	    .element = w->p->kinds[kind].element };
	if (item->kind == ERX_ETF_NIL) {
		store_value(store, &view, sizeof(view));
		w->done_key = (key_t){ .valid = false };
		return (complete(w));
	}
	if (item->kind != ERX_ETF_LIST && item->kind != ERX_ETF_STRING)
		return (refuse(w, ERX_PROFILE_SHAPE, kind));
	if (!push(w, kind, store, &l))
		return (false);
	if (item->kind == ERX_ETF_LIST)
		l->segment_left = item->count;
	else {
		l->in_string = true;
		l->string = item->u.data.bytes;
		l->string_left = (uint32_t)item->u.data.len;
	}
	view.segment_left = l->segment_left;
	view.string = l->string;
	view.string_left = l->string_left;
	store_value(store, &view, sizeof(view));
	return (true);
}

/* Starts a union tuple of item->count elements: its candidates by arity. */
static bool
begin_union(walk_t *w, uint16_t kind, const erx_etf_item_t *item, uint8_t *store)
{
	const erx_profile_kind_t *k;
	uint64_t candidates;
	level_t *l;
	uint16_t c;

	k = &w->p->kinds[kind];
	candidates = 0;
	for (c = 0; c < k->ncases; c++) {
		if (k->cases[c].nfields != 0 &&
		    (uint32_t)k->cases[c].natoms + k->cases[c].nfields ==
		    item->count)
			candidates |= UINT64_C(1) << c;
	}
	if (candidates == 0)
		return (refuse(w, ERX_PROFILE_NO_CASE, kind));
	if (!push(w, kind, store, &l))
		return (false);
	l->seen = candidates;
	l->arity = item->count;
	return (true);
}

/*
 * Reads one term of kind into store (NULL to store nothing): judges a
 * scalar whole, or pushes the level a container's children are read in.
 */
static bool
begin(walk_t *w, uint16_t kind, uint8_t *store)
{
	const erx_profile_kind_t *k;
	erx_etf_item_t item;
	uint64_t v;
	int32_t number;
	uint16_t i;
	level_t *l;
	bool b;

	k = &w->p->kinds[kind];
	if (!read_term(w, &item, kind))
		return (false);
	switch (k->form) {
	case ERX_PROFILE_INTEGER:
		if (item.kind != ERX_ETF_INTEGER && item.kind != ERX_ETF_BIG)
			return (refuse(w, ERX_PROFILE_SHAPE, kind));
		if (!item_u64(&item, &v))
			return (refuse(w, ERX_PROFILE_RANGE, kind));
		return (judge_integer(w, kind, v, store));
	case ERX_PROFILE_TEXT_FORM:
		return (judge_text(w, kind, &item, store));
	case ERX_PROFILE_BOOLEAN:
		if (!atom_is(&item, "true") && !atom_is(&item, "false"))
			return (refuse(w, ERX_PROFILE_SHAPE, kind));
		b = atom_is(&item, "true");
		store_value(store, &b, sizeof(b));
		w->done_key = (key_t){ .atom = item.u.data.bytes,
		    .len = item.u.data.len, .is_atom = true, .valid = true };
		return (complete(w));
	case ERX_PROFILE_SIGNAL:
		if (item.kind != ERX_ETF_ATOM)
			return (refuse(w, ERX_PROFILE_SHAPE, kind));
		for (i = 0; i < w->p->nsignals; i++) {
			if (atom_is(&item, w->p->signals[i].name))
				break;
		}
		if (i == w->p->nsignals)
			return (refuse(w, ERX_PROFILE_RANGE, kind));
		number = w->p->signals[i].number;
		store_value(store, &number, sizeof(number));
		w->done_key = (key_t){ .atom = item.u.data.bytes,
		    .len = item.u.data.len, .is_atom = true, .valid = true };
		return (complete(w));
	case ERX_PROFILE_ATOMS:
	case ERX_PROFILE_UNION:
		if (item.kind == ERX_ETF_ATOM)
			return (judge_atom_case(w, kind, &item, store));
		if (item.kind != ERX_ETF_TUPLE)
			return (refuse(w, ERX_PROFILE_SHAPE, kind));
		if (k->form == ERX_PROFILE_ATOMS)
			return (refuse(w, ERX_PROFILE_NO_CASE, kind));
		return (begin_union(w, kind, &item, store));
	case ERX_PROFILE_TUPLE:
		if (item.kind != ERX_ETF_TUPLE || item.count != k->nfields)
			return (refuse(w, ERX_PROFILE_SHAPE, kind));
		if (!push(w, kind, store, &l))
			return (false);
		l->arity = item.count;
		return (true);
	case ERX_PROFILE_MAP:
		if (item.kind != ERX_ETF_MAP)
			return (refuse(w, ERX_PROFILE_SHAPE, kind));
		if (!push(w, kind, store, &l))
			return (false);
		l->index = item.count;
		return (true);
	case ERX_PROFILE_LIST:
		return (begin_list(w, kind, &item, store));
	}
	return (refuse(w, ERX_PROFILE_MALFORMED, kind));
}

/* Pops the top level; its value is done. */
static bool
pop(walk_t *w)
{
	level_t *l;
	uint16_t which;
	uint16_t c;

	l = &w->stack[w->top - 1];
	w->done_key = (key_t){ .valid = false };
	switch (l->k->form) {
	case ERX_PROFILE_TUPLE:
		w->done_key = l->key;
		break;
	case ERX_PROFILE_UNION:
		for (c = 0; c < l->k->ncases; c++) {
			if (l->seen & UINT64_C(1) << c)
				break;
		}
		which = c;
		store_value(l->store, &which, sizeof(which));
		break;
	case ERX_PROFILE_LIST:
		if (l->store != NULL)
			memcpy(l->store + offsetof(erx_profile_list_t, left),
			    &l->count, sizeof(l->count));
		break;
	default:
		break;
	}
	w->top--;
	return (complete(w));
}

/* The next element of the list at l, or its end. */
static bool
step_list(walk_t *w, level_t *l)
{
	erx_etf_item_t item;
	uint8_t byte;

	while (!l->in_string && l->segment_left == 0) {
		/* A segment's tail: another segment, or the list's end. */
		if (!read_term(w, &item, l->kind))
			return (false);
		if (item.kind == ERX_ETF_NIL)
			return (pop(w));
		if (item.kind == ERX_ETF_LIST)
			l->segment_left = item.count;
		else if (item.kind == ERX_ETF_STRING) {
			l->in_string = true;
			l->string = item.u.data.bytes;
			l->string_left = (uint32_t)item.u.data.len;
		} else
			return (refuse(w, ERX_PROFILE_SHAPE, l->kind));
	}
	if (l->in_string && l->string_left == 0)
		return (pop(w));
	if (l->count == l->k->list_max)
		return (refuse(w, ERX_PROFILE_LENGTH, l->kind));
	l->count++;
	l->held_refers = false;
	if (!l->in_string) {
		l->segment_left--;
		return (begin(w, l->k->element, NULL));
	}
	/* A STRING_EXT's byte is an integer element. */
	w->item = (size_t)(l->string - w->rd.bytes);
	byte = *l->string++;
	l->string_left--;
	if (w->p->kinds[l->k->element].form != ERX_PROFILE_INTEGER)
		return (refuse(w, ERX_PROFILE_SHAPE, l->k->element));
	return (judge_integer(w, l->k->element, byte, NULL));
}

static bool
step_map(walk_t *w, level_t *l)
{
	const erx_profile_field_t *f;
	erx_etf_item_t item;
	uint64_t required;
	uint16_t i;
	bool has;

	if (l->index == 0) {
		required = 0;
		for (i = 0; i < l->k->nfields; i++) {
			if (l->k->fields[i].has_offset == ERX_PROFILE_NONE)
				required |= UINT64_C(1) << i;
		}
		if ((l->seen & required) != required)
			return (refuse(w, ERX_PROFILE_KEY, l->kind));
		return (pop(w));
	}
	l->index--;
	if (!read_term(w, &item, l->kind))
		return (false);
	for (i = 0; i < l->k->nfields; i++) {
		if (atom_is(&item, l->k->fields[i].name))
			break;
	}
	if (i == l->k->nfields)
		return (refuse(w, ERX_PROFILE_KEY, l->kind));
	/* ERTS's decoder refuses a map with a key repeated. */
	if (l->seen & UINT64_C(1) << i)
		return (refuse(w, ERX_PROFILE_MALFORMED, l->kind));
	l->seen |= UINT64_C(1) << i;
	f = &l->k->fields[i];
	has = true;
	if (f->has_offset != ERX_PROFILE_NONE && l->store != NULL)
		store_value(l->store + f->has_offset, &has, sizeof(has));
	return (begin(w, f->kind,
	    l->store == NULL ? NULL : l->store + f->offset));
}

static bool
step_union(walk_t *w, level_t *l)
{
	const erx_profile_case_t *c;
	erx_etf_item_t item;
	uint16_t i, first;

	if (l->index == l->arity)
		return (pop(w));
	for (first = 0; first < l->k->ncases; first++) {
		if (l->seen & UINT64_C(1) << first)
			break;
	}
	c = &l->k->cases[first];
	if (l->index < c->natoms) {
		/* Candidates past the first atom share the case atom, so their count of atoms too. */
		if (!read_term(w, &item, l->kind))
			return (false);
		for (i = first; i < l->k->ncases; i++) {
			if ((l->seen & UINT64_C(1) << i) && (l->index >=
			    l->k->cases[i].natoms ||
			    !atom_is(&item, l->k->cases[i].atoms[l->index])))
				l->seen &= ~(UINT64_C(1) << i);
		}
		if (l->seen == 0)
			return (refuse(w, ERX_PROFILE_NO_CASE, l->kind));
		l->index++;
		return (true);
	}
	i = (uint16_t)(l->index++ - c->natoms);
	return (begin(w, c->fields[i].kind, l->store == NULL ? NULL :
	    l->store + c->offset + c->fields[i].offset));
}

/* Advances the top level by one child, or pops it. */
static bool
step(walk_t *w)
{
	level_t *l;
	const erx_profile_field_t *f;

	l = &w->stack[w->top - 1];
	switch (l->k->form) {
	case ERX_PROFILE_TUPLE:
		if (l->index == l->arity)
			return (pop(w));
		f = &l->k->fields[l->index++];
		return (begin(w, f->kind,
		    l->store == NULL ? NULL : l->store + f->offset));
	case ERX_PROFILE_LIST:
		return (step_list(w, l));
	case ERX_PROFILE_MAP:
		return (step_map(w, l));
	case ERX_PROFILE_UNION:
		return (step_union(w, l));
	default:
		return (refuse(w, ERX_PROFILE_MALFORMED, l->kind));
	}
}

/* Reads one term of kind and every term inside it. */
static bool
walk_term(walk_t *w, uint16_t kind, uint8_t *store)
{
	if (!begin(w, kind, store))
		return (false);
	while (w->top > 0) {
		if (!step(w))
			return (false);
	}
	return (true);
}

/* The bytes of one of refers rule r's two bitmaps. */
static size_t
bitmap_size(const erx_profile_refers_t *r)
{
	return (((size_t)r->range + 7) / 8);
}

/* The bytes of every refers rule's two bitmaps; false when they overflow. */
static bool
bitmap_bytes(const erx_profile_t *p, size_t *total)
{
	size_t i, n;

	n = 0;
	for (i = 0; i < p->nrefers; i++) {
		if (n > SIZE_MAX - 2 * bitmap_size(&p->refers[i]))
			return (false);
		n += 2 * bitmap_size(&p->refers[i]);
	}
	*total = n;
	return (true);
}

size_t
erx_profile_scratch_bytes(const erx_profile_t *p, size_t len)
{
	size_t bitmaps, n;

	if (!bitmap_bytes(p, &bitmaps))
		return (SIZE_MAX);
	n = len / 2;
	if (n > (SIZE_MAX - 7) / 8)
		return (SIZE_MAX);
	n = 7 + 8 * n;
	if (n > SIZE_MAX - bitmaps)
		return (SIZE_MAX);
	return (n + bitmaps);
}

static void
sift(uint64_t *a, size_t root, size_t n)
{
	size_t child;
	uint64_t t;

	for (;;) {
		child = 2 * root + 1;
		if (child >= n)
			return;
		if (child + 1 < n && a[child] < a[child + 1])
			child++;
		if (a[root] >= a[child])
			return;
		t = a[root];
		a[root] = a[child];
		a[child] = t;
		root = child;
	}
}

/* An in-place heapsort: no recursion, no allocation. */
static void
sort_u64(uint64_t *a, size_t n)
{
	size_t i;
	uint64_t t;

	for (i = n / 2; i > 0; i--)
		sift(a, i - 1, n);
	for (i = n; i > 1; i--) {
		t = a[0];
		a[0] = a[i - 1];
		a[i - 1] = t;
		sift(a, 0, i - 1);
	}
}

/* The frame-wide rules, once the walk ends: each total, unique, refers. */
static bool
frame_rules(walk_t *w)
{
	const erx_profile_refers_t *r;
	const uint8_t *referred, *targets;
	size_t i, j, bytes;

	w->item = w->rd.len;
	for (i = 0; i < w->p->ntotals; i++) {
		if (w->sums[i] > w->p->totals[i].max)
			return (refuse(w, ERX_PROFILE_TOTAL,
			    w->p->totals[i].name));
	}
	sort_u64(w->uniq, w->nuniq);
	for (i = 1; i < w->nuniq; i++) {
		if (w->uniq[i - 1] == w->uniq[i])
			return (refuse(w, ERX_PROFILE_UNIQUE,
			    w->p->unique_kind));
	}
	referred = w->bitmaps;
	for (i = 0; i < w->p->nrefers; i++) {
		r = &w->p->refers[i];
		bytes = bitmap_size(r);
		targets = referred + bytes;
		for (j = 0; j < bytes; j++) {
			if ((referred[j] & ~targets[j]) != 0)
				return (refuse(w, ERX_PROFILE_REFERS, r->kind));
		}
		referred = targets + bytes;
	}
	return (true);
}

/* The envelope {Tag, Version, [Slot,] Value}, then the value. */
static bool
walk_frame(walk_t *w, const erx_profile_frame_t *f, uint8_t *slot, void *out)
{
	erx_etf_item_t item;
	uint64_t v;

	if (!read_term(w, &item, f->name))
		return (false);
	if (item.kind != ERX_ETF_TUPLE || item.count != (f->slot ? 4u : 3u))
		return (refuse(w, ERX_PROFILE_SHAPE, f->name));
	if (!read_term(w, &item, f->name))
		return (false);
	if (!atom_is(&item, f->tag))
		return (refuse(w, ERX_PROFILE_SHAPE, f->name));
	if (!read_term(w, &item, f->name))
		return (false);
	if ((item.kind != ERX_ETF_INTEGER && item.kind != ERX_ETF_BIG) ||
	    !item_u64(&item, &v) || v != w->p->version)
		return (refuse(w, ERX_PROFILE_VERSION, f->name));
	if (f->slot && !walk_term(w, w->p->slot_kind, slot))
		return (false);
	return (walk_term(w, f->kind, out));
}

bool
erx_profile_check(const erx_profile_t *p, uint16_t frame, const uint8_t *bytes,
    size_t len, void *scratch, size_t scratch_len, uint8_t *slot, void *out,
    erx_profile_refusal_t *refusal)
{
	const erx_profile_frame_t *f;
	erx_etf_reason_t reason;
	erx_etf_item_t item;
	size_t bitmaps, pad, need;
	walk_t w;

	f = &p->frames[frame];
	*refusal = (erx_profile_refusal_t){ .reason = ERX_PROFILE_OK,
	    .kind = f->name };
	if (len > p->frame_max) {
		refusal->reason = ERX_PROFILE_SIZE;
		return (false);
	}
	need = erx_profile_scratch_bytes(p, len);
	if (scratch_len < need || !bitmap_bytes(p, &bitmaps)) {
		refusal->reason = ERX_PROFILE_SCRATCH;
		return (false);
	}
	pad = (size_t)(-(uintptr_t)scratch & 7);
	memset(&w, 0, sizeof(w));
	w.p = p;
	w.refusal = refusal;
	w.global = true;
	w.uniq = (uint64_t *)(void *)((uint8_t *)scratch + pad);
	w.uniq_cap = len / 2;
	w.bitmaps = (uint8_t *)scratch + pad + 8 * w.uniq_cap;
	memset(w.bitmaps, 0, bitmaps);
	if (!erx_etf_reader_init(&w.rd, bytes, len)) {
		refusal->reason = ERX_PROFILE_MALFORMED;
		return (false);
	}
	if (!walk_frame(&w, f, slot, out))
		return (false);
	w.item = w.rd.pos;
	if (erx_etf_next(&w.rd, &item, &reason) != ERX_ETF_STEP_END)
		return (refuse(&w, ERX_PROFILE_MALFORMED, f->name));
	return (frame_rules(&w));
}

bool
erx_profile_next(erx_profile_list_t *list, void *element)
{
	erx_profile_refusal_t refusal;
	erx_etf_item_t item;
	uint8_t byte;
	walk_t w;

	if (list->left == 0)
		return (false);
	memset(&w, 0, sizeof(w));
	w.p = list->profile;
	w.refusal = &refusal;
	w.rd = (erx_etf_reader_t){ .bytes = list->frame, .len = list->len,
	    .pos = list->pos };
	for (;;) {
		if (list->string_left > 0) {
			/* A STRING_EXT segment's byte is an integer element. */
			byte = *list->string++;
			list->string_left--;
			list->left--;
			store_integer(element, byte,
			    w.p->kinds[list->element].size);
			return (true);
		}
		if (list->segment_left > 0)
			break;
		/* The accepted list goes on in another segment. */
		if (!read_term(&w, &item, list->element))
			return (false);
		list->pos = w.rd.pos;
		if (item.kind == ERX_ETF_LIST)
			list->segment_left = item.count;
		else if (item.kind == ERX_ETF_STRING) {
			list->string = item.u.data.bytes;
			list->string_left = (uint32_t)item.u.data.len;
		} else
			return (false);
	}
	if (!walk_term(&w, list->element, element))
		return (false);
	list->segment_left--;
	list->left--;
	list->pos = w.rd.pos;
	return (true);
}
