/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 *
 * Reads a stream of the widget server's records from standard input with the
 * generated erx_ui_read() and prints one line per record naming what it read,
 * in the format of erx_ui_wire_tests:corpus/3 with numbers where that has
 * names, and every property's status block. Exits 1 at a refused record or a
 * stream that ends inside one.
 *
 * With the arguments "write PATH SEED", writes the other way instead: random
 * event and damage records, with the generated writer, to PATH, and one line
 * per record to standard output naming what it wrote, in the format of
 * erx_ui_wire_tests:read_corpus/2 with the event's number for its name. It
 * checks on the way that each record fits a buffer of exactly its size and is
 * refused by one byte less, and that the writer refuses what the form cannot
 * hold; it exits 1 at the first that does not.
 *
 * With the argument "each", reads on past a refused record instead,
 * printing "refused: REASON" for it and skipping the bytes its length word
 * counts, and stops, exiting 0, at "refused: bad length" or at "more" for a
 * stream that ends inside a record: the differential corpus of mutated
 * records, whose lines the TypeScript harness must print the same.
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include <erx/ui_wire.h>

static void
print_hex(erx_ui_bytes_t bytes)
{
	putchar('x');
	for (uint32_t index = 0; index < bytes.length; index++)
		printf("%02x", bytes.data[index]);
}

static void
print_value(const erx_ui_prop_t *prop)
{
	erx_ui_bytes_t text;
	uint32_t cursor;

	if (!prop->has_value) {
		putchar('-');
		return;
	}
	switch (prop->form) {
	case ERX_UI_FORM_TEXT:
	case ERX_UI_FORM_BYTES:
		print_hex(prop->bytes);
		break;
	case ERX_UI_FORM_LIST:
		putchar('[');
		cursor = 0;
		for (uint16_t index = 0; erx_ui_list_next(prop, &cursor, &text);
		    index++) {
			if (index > 0)
				putchar(',');
			print_hex(text);
		}
		putchar(']');
		break;
	case ERX_UI_FORM_PRESENTATION:
		print_hex(prop->name);
		putchar(':');
		print_hex(prop->bytes);
		break;
	default:
		printf("%d", (int)prop->integer);
		break;
	}
}

static void
print_props(const erx_ui_record_t *record)
{
	const erx_ui_prop_t *prop;

	for (uint8_t index = 0; index < record->nprops; index++) {
		prop = &record->props[index];
		printf(" %u=%u,%u,%.*s,%u:", prop->number, prop->status,
		    prop->reporter, (int)prop->stopgap.length,
		    (const char *)prop->stopgap.data, prop->timeout_ms);
		print_value(prop);
	}
}

static void
print_record(const erx_ui_record_t *record)
{
	switch (record->tag) {
	case ERX_UI_INSERT:
		printf("insert %u %u %u %u", record->node, record->parent,
		    record->index, record->kind);
		print_props(record);
		break;
	case ERX_UI_SET:
		printf("set %u", record->node);
		print_props(record);
		printf(" /");
		for (uint8_t index = 0; index < record->nremoved; index++)
			printf(" %u", record->removed[index]);
		break;
	case ERX_UI_REMOVE:
		printf("remove %u", record->node);
		break;
	case ERX_UI_MOVE:
		printf("move %u %u", record->node, record->index);
		break;
	case ERX_UI_COMMIT:
		printf("commit");
		break;
	case ERX_UI_REPAINT:
		printf("repaint");
		break;
	case ERX_UI_PRESENTED:
		printf("presented");
		break;
	case ERX_UI_SCREEN:
		printf("screen %u %u %u", record->width, record->height,
		    record->chan);
		break;
	case ERX_UI_INPUT:
		if (record->input == ERX_UI_INPUT_POINTER)
			printf("pointer %u %u %u", record->x, record->y,
			    record->buttons);
		else if (record->input == ERX_UI_INPUT_WHEEL)
			printf("wheel %d", record->steps);
		else if (record->rune == ERX_UI_RUNE_NONE)
			printf("key %s %u none", record->down ? "down" : "up",
			    record->code);
		else
			printf("key %s %u %u", record->down ? "down" : "up",
			    record->code, record->rune);
		break;
	}
	putchar('\n');
}

/* xorshift64: the corpus is a function of the seed. */
static uint64_t
next_random(uint64_t *state)
{
	*state ^= *state << 13;
	*state ^= *state >> 7;
	*state ^= *state << 17;
	return (*state);
}

static uint32_t
below(uint64_t *state, uint32_t bound)
{
	return ((uint32_t)(next_random(state) % bound));
}

/* At most max bytes of valid UTF-8 of scalars of every encoded length. */
static uint32_t
random_utf8(uint64_t *state, uint8_t *out, uint32_t max)
{
	static const uint32_t lowest[] = { 0x20, 0x80, 0x800, 0x10000 };
	static const uint32_t highest[] = { 0x7e, 0x7ff, 0xffff, 0x10ffff };
	static const uint8_t lead[] = { 0, 0, 0xc0, 0xe0, 0xf0 };
	uint32_t bytes, length, point, range;

	length = 0;
	for (;;) {
		range = below(state, 4);
		point = lowest[range] +
		    below(state, highest[range] - lowest[range] + 1);
		if (point >= 0xd800 && point <= 0xdfff)
			point = 0xfffd;
		bytes = point < 0x80 ? 1 : point < 0x800 ? 2 :
		    point < 0x10000 ? 3 : 4;
		if (bytes > max - length)
			return (length);
		if (bytes == 1) {
			out[length++] = (uint8_t)point;
			continue;
		}
		out[length++] = (uint8_t)(lead[bytes] |
		    (point >> (6 * (bytes - 1))));
		for (uint32_t shift = 6 * (bytes - 1); shift > 0; shift -= 6)
			out[length++] = (uint8_t)(0x80 | ((point >> (shift - 6)) &
			    0x3f));
	}
}

/*
 * Write one record by write_one into a buffer of exactly its size after
 * checking that one byte less is refused, and append it to out.
 */
typedef size_t (*writer_t)(uint8_t *, size_t, const void *);

static void
emit(FILE *out, writer_t write_one, const void *what)
{
	static uint8_t record[ERX_UI_OP_MAX + 4];
	size_t size;

	size = write_one(record, sizeof(record), what);
	if (size < 5) {
		fprintf(stderr, "writer refused a valid record\n");
		exit(1);
	}
	if (write_one(record, size - 1, what) != 0) {
		fprintf(stderr, "writer accepted a buffer one byte short\n");
		exit(1);
	}
	if (write_one(record, size, what) != size) {
		fprintf(stderr, "writer refused a buffer of the record's size\n");
		exit(1);
	}
	fwrite(record, 1, size, out);
}

typedef struct event event_t;
struct event {
	erx_ui_detail_t	 detail;
	uint32_t	 node;
	uint8_t		 number;
};

typedef struct damage damage_t;
struct damage {
	erx_ui_rect_t	 rects[ERX_UI_DAMAGE_MAX + 1];
	size_t		 count;
	uint16_t	 width;		/* the size the report was drawn at */
	uint16_t	 height;
};

static size_t
write_event(uint8_t *buffer, size_t size, const void *what)
{
	const event_t *event = what;

	return (erx_ui_write_event(buffer, size, event->node, event->number,
	    &event->detail));
}

static size_t
write_damage(uint8_t *buffer, size_t size, const void *what)
{
	const damage_t *damage = what;

	return (erx_ui_write_damage(buffer, size, damage->width,
	    damage->height, damage->rects, damage->count));
}

/* What the writer must refuse, whatever the buffer; exits at the first not. */
static void
check_refusals(uint8_t event_number, uint8_t other_number)
{
	static uint8_t buffer[ERX_UI_OP_MAX + 4], source[ERX_UI_OP_MAX];
	static const uint8_t bad_utf8[] = { 'a', 0xc0, 0x80 };
	static const uint8_t surrogate[] = { 0xed, 0xa0, 0x80 };
	const event_t refused[] = {
		{ .node = 0, .number = event_number },
		{ .node = 1, .number = other_number },
		{ .node = 1, .number = event_number,
		    .detail = { .tag = ERX_UI_DETAIL_BOOLEAN, .integer = 2 } },
		{ .node = 1, .number = event_number,
		    .detail = { .tag = ERX_UI_DETAIL_TEXT, .text = { bad_utf8, 3 } } },
		{ .node = 1, .number = event_number,
		    .detail = { .tag = ERX_UI_DETAIL_TEXT, .text = { surrogate, 3 } } },
		{ .node = 1, .number = event_number,
		    .detail = { .tag = ERX_UI_DETAIL_TEXT,
		    .text = { source, ERX_UI_EVENT_TEXT_MAX + 1 } } },
		{ .node = 1, .number = event_number,
		    .detail = { .tag = ERX_UI_DETAIL_TEXT + 1 } }
	};
	/*
	 * Drawn at 2 by 2: no rectangle, one too many, one of no width or of no
	 * height, and one that leaves the size by a column or by a row.
	 */
	damage_t damages[6] = {
		{ .count = 0, .width = 2, .height = 2 },
		{ .count = ERX_UI_DAMAGE_MAX + 1, .width = 2, .height = 2 },
		{ .count = 2, .width = 2, .height = 2 },
		{ .count = 1, .width = 2, .height = 2 },
		{ .count = 1, .width = 2, .height = 2 },
		{ .count = 1, .width = 2, .height = 2 }
	};

	memset(source, 'a', sizeof(source));
	for (size_t index = 0; index < sizeof(refused) / sizeof(refused[0]);
	    index++) {
		if (write_event(buffer, sizeof(buffer), &refused[index]) != 0) {
			fprintf(stderr, "writer wrote refused event %zu\n", index);
			exit(1);
		}
	}
	for (size_t index = 0; index <= ERX_UI_DAMAGE_MAX; index++)
		damages[1].rects[index] = (erx_ui_rect_t){ .width = 1,
		    .height = 1 };
	damages[2].rects[0] = (erx_ui_rect_t){ .width = 1, .height = 1 };
	damages[2].rects[1] = (erx_ui_rect_t){ .width = 0, .height = 1 };
	damages[3].rects[0] = (erx_ui_rect_t){ .width = 1, .height = 0 };
	damages[4].rects[0] = (erx_ui_rect_t){ .x = 1, .width = 2,
	    .height = 1 };
	damages[5].rects[0] = (erx_ui_rect_t){ .y = 1, .width = 1,
	    .height = 2 };
	for (size_t index = 0; index < sizeof(damages) / sizeof(damages[0]);
	    index++) {
		if (write_damage(buffer, sizeof(buffer), &damages[index]) != 0) {
			fprintf(stderr, "writer wrote refused damage %zu\n",
			    index);
			exit(1);
		}
	}
}

static void
print_bytes(const uint8_t *data, size_t length)
{
	putchar('x');
	for (size_t index = 0; index < length; index++)
		printf("%02x", data[index]);
}

/*
 * Every event property, each detail tag at its bounds and at random, and
 * damage reports of one rectangle to the most; the event numbers are those the
 * writer accepts, which the reader on the other side names.
 */
static int
write_corpus(const char *path, uint64_t seed)
{
	static uint8_t data[ERX_UI_OP_MAX];
	static const int32_t integers[] = { 0, 1, -1, INT32_MIN, INT32_MAX };
	const erx_ui_detail_t none = { .tag = ERX_UI_DETAIL_NONE };
	uint8_t events[256], probe[16], refused_number;
	uint64_t state;
	uint32_t count, nevents, max;
	event_t event;
	damage_t damage;
	FILE *out;

	_Static_assert(ERX_UI_EVENT_TEXT_MAX <= sizeof(data),
	    "an event's longest text fits the corpus's buffer");
	nevents = 0;
	refused_number = 0;
	for (uint32_t number = 0; number < 256; number++) {
		if (erx_ui_write_event(probe, sizeof(probe), 1, (uint8_t)number,
		    &none) != 0)
			events[nevents++] = (uint8_t)number;
		else
			refused_number = (uint8_t)number;
	}
	if (nevents == 0 || nevents == 256)
		return (1);
	check_refusals(events[0], refused_number);
	count = 0;
	if ((out = fopen(path, "wb")) == NULL)
		return (1);
	state = seed * 0x9e3779b97f4a7c15ULL + 1;
	for (uint32_t index = 0; index < 600; index++) {
		if (index % 3 == 2) {
			damage.count = index % 50 == 2 ? ERX_UI_DAMAGE_MAX :
			    1 + below(&state, ERX_UI_DAMAGE_MAX);
			damage.width = (uint16_t)(1 + below(&state, 65535));
			damage.height = (uint16_t)(1 + below(&state, 65535));
			printf("damage %u %u", damage.width, damage.height);
			for (size_t at = 0; at < damage.count; at++) {
				uint16_t x = (uint16_t)below(&state, damage.width);
				uint16_t y = (uint16_t)below(&state, damage.height);

				damage.rects[at] = (erx_ui_rect_t){ .x = x, .y = y,
				    .width = (uint16_t)(1 +
				    below(&state, damage.width - x)),
				    .height = (uint16_t)(1 +
				    below(&state, damage.height - y)) };
				printf(" %u %u %u %u", damage.rects[at].x,
				    damage.rects[at].y, damage.rects[at].width,
				    damage.rects[at].height);
			}
			emit(out, write_damage, &damage);
			putchar('\n');
			continue;
		}
		event = (event_t){ .number = events[count++ % nevents],
		    .node = index % 7 == 0 ? UINT32_MAX :
		    1 + below(&state, UINT32_MAX),
		    .detail = { .tag = (uint8_t)(index % 4) } };
		printf("event %u %u ", event.node, event.number);
		switch (event.detail.tag) {
		case ERX_UI_DETAIL_NONE:
			printf("none");
			break;
		case ERX_UI_DETAIL_BOOLEAN:
			event.detail.integer = (int32_t)below(&state, 2);
			fputs(event.detail.integer ? "true" : "false", stdout);
			break;
		case ERX_UI_DETAIL_INTEGER:
			event.detail.integer = index % 5 == 0 ?
			    integers[below(&state, 5)] :
			    (int32_t)next_random(&state);
			printf("%d", (int)event.detail.integer);
			break;
		case ERX_UI_DETAIL_TEXT:
			max = index % 41 == 3 ? ERX_UI_EVENT_TEXT_MAX :
			    below(&state, 41);
			event.detail.text.data = data;
			event.detail.text.length = random_utf8(&state, data, max);
			print_bytes(data, event.detail.text.length);
			break;
		}
		putchar('\n');
		emit(out, write_event, &event);
	}
	return (fclose(out) == 0 ? 0 : 1);
}

int
main(int argc, char **argv)
{
	static uint8_t stream[64 << 20];
	erx_ui_record_t record;
	size_t length, offset, used;
	bool each;

	each = argc == 2 && strcmp(argv[1], "each") == 0;
	if (argc == 4 && strcmp(argv[1], "write") == 0)
		return (write_corpus(argv[2], strtoull(argv[3], NULL, 10)));
	length = fread(stream, 1, sizeof(stream), stdin);
	if (length == sizeof(stream)) {
		fprintf(stderr, "stream too long\n");
		return (1);
	}
	for (offset = 0; offset < length; offset += used) {
		switch (erx_ui_read(stream + offset, length - offset, &record,
		    &used)) {
		case ERX_UI_READ_OK:
			print_record(&record);
			break;
		case ERX_UI_READ_MORE:
			if (each) {
				printf("more\n");
				return (0);
			}
			fprintf(stderr, "stream ends inside a record at %zu\n",
			    offset);
			return (1);
		case ERX_UI_READ_BAD:
			if (each) {
				printf("refused: %s\n", record.reason);
				if (strcmp(record.reason, "bad length") == 0)
					return (0);
				/* A length word the reader accepted: whole, at most ERX_UI_OP_MAX. */
				used = 4 + ((size_t)stream[offset] |
				    (size_t)stream[offset + 1] << 8 |
				    (size_t)stream[offset + 2] << 16 |
				    (size_t)stream[offset + 3] << 24);
				break;
			}
			fprintf(stderr, "refused at %zu: %s\n", offset,
			    record.reason);
			return (1);
		}
	}
	return (0);
}
