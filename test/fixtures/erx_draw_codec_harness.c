/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 *
 * The C side of the draw codec's differential test
 * (test/host/erx_draw_codec_test.rb). It reads a corpus of cases, each a
 * u32 length and that many bytes, from the file named by its argument, and
 * decodes each case as erx_draw_codec_tests:decode_corpus/2 does: the
 * first 8 bytes give the depths of ids 0 to 7, a byte b giving b mod 33, 0
 * for none, and the rest is decoded message by message to its end or its
 * first error. It prints one line per message, as the Erlang side does:
 * the name, the fields and the offset after it, or the errno and the
 * failed field's offset, then "end".
 */

#include <inttypes.h>
#include <stdio.h>
#include <stdlib.h>

#include <erx/draw_codec.h>

#define DEPTH_IDS 8

static int
depth_of(void *arg, uint32_t id)
{
	const uint8_t *depths = arg;

	return (id < DEPTH_IDS ? depths[id] : 0);
}

static void
print_value(const erx_draw_field_t *field, const erx_draw_value_t *value)
{
	size_t cursor;
	int32_t x, y;

	switch (field->type) {
	case ERX_DRAW_F_POINT:
		printf(" %" PRId32 ",%" PRId32, value->xy[0], value->xy[1]);
		break;
	case ERX_DRAW_F_RECT:
		printf(" %" PRId32 ",%" PRId32 ",%" PRId32 ",%" PRId32,
		    value->xy[0], value->xy[1], value->xy[2], value->xy[3]);
		break;
	case ERX_DRAW_F_POINTS:
		cursor = 0;
		for (uint32_t n = 0; erx_draw_points_next(value, &cursor, &x, &y);
		    n++)
			printf("%s%" PRId32 ",%" PRId32, n == 0 ? " " : ";", x, y);
		break;
	case ERX_DRAW_F_INDICES:
		if (value->count == 0)
			printf(" -");
		for (uint32_t n = 0; n < value->count; n++)
			printf("%s%u", n == 0 ? " " : ";",
			    value->data[2 * n] | value->data[2 * n + 1] << 8);
		break;
	case ERX_DRAW_F_PIXELS:
		printf(" %zu", value->length);
		break;
	case ERX_DRAW_F_COMPRESSED:
		printf(" -");
		break;
	default:
		printf(" %" PRId64, value->scalar);
		break;
	}
}

static void
decode_case(const uint8_t *data, size_t size)
{
	static const char *errnos[] = { "ok", "einval", "enoent" };
	uint8_t depths[DEPTH_IDS] = { 0 };
	erx_draw_msg_t msg;
	size_t at, used, offset;
	int status;

	for (size_t i = 0; i < DEPTH_IDS && i < size; i++)
		depths[i] = data[i] % 33;
	for (at = DEPTH_IDS; at < size; at += used) {
		status = erx_draw_decode(data + at, size - at, depth_of, depths,
		    &msg, &used, &offset);
		if (status != ERX_DRAW_OK) {
			printf("error %s %zu\n", errnos[status],
			    at - DEPTH_IDS + offset);
			break;
		}
		printf("%s", msg.layout->name);
		for (uint8_t i = 0; i < msg.layout->nfields; i++) {
			if (msg.layout->fields[i].type != ERX_DRAW_F_COUNT)
				print_value(&msg.layout->fields[i], &msg.values[i]);
		}
		printf(" @%zu\n", at + used - DEPTH_IDS);
	}
	printf("end\n");
}

int
main(int argc, char **argv)
{
	FILE *file;
	uint8_t *data;
	long length;
	size_t at, size;

	if (argc != 2 || (file = fopen(argv[1], "rb")) == NULL)
		return (2);
	if (fseek(file, 0, SEEK_END) != 0 || (length = ftell(file)) < 0 ||
	    fseek(file, 0, SEEK_SET) != 0)
		return (2);
	if ((data = malloc((size_t)length + 1)) == NULL ||
	    fread(data, 1, (size_t)length, file) != (size_t)length)
		return (2);
	fclose(file);
	for (at = 0; (size_t)length - at >= 4; at += size) {
		size = (size_t)data[at] | (size_t)data[at + 1] << 8 |
		    (size_t)data[at + 2] << 16 | (size_t)data[at + 3] << 24;
		at += 4;
		if (size > (size_t)length - at)
			return (2);
		decode_case(data + at, size);
	}
	free(data);
	return (at == (size_t)length ? 0 : 2);
}
