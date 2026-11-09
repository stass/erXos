/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 *
 * The draw codec's C twin (erx/draw_codec.h), generated from
 * abi/formats/draw.txt, fed what a hostile draw client could write. The
 * input's first 8 bytes give the depths of ids 0 to 7, a byte b giving
 * b mod 33, 0 for none; the rest is decoded message by message to its end
 * or its first error. Each message must take at least its letter and no
 * byte past the input, each variable field must lie within the message,
 * and a failure's offset must lie within the bytes left.
 */

#include <stddef.h>
#include <stdint.h>
#include <stdlib.h>

#include <erx/draw_codec.h>

#define DEPTH_IDS 8

int LLVMFuzzerTestOneInput(const uint8_t *, size_t);

static int
depth_of(void *arg, uint32_t id)
{
	const uint8_t *depths = arg;

	return (id < DEPTH_IDS ? depths[id] : 0);
}

int
LLVMFuzzerTestOneInput(const uint8_t *data, size_t size)
{
	uint8_t depths[DEPTH_IDS];
	erx_draw_msg_t msg;
	const erx_draw_value_t *value;
	size_t at, used, offset;

	if (size < DEPTH_IDS)
		return (0);
	for (size_t i = 0; i < DEPTH_IDS; i++)
		depths[i] = data[i] % 33;
	for (at = DEPTH_IDS; at < size; at += used) {
		if (erx_draw_decode(data + at, size - at, depth_of, depths, &msg,
		    &used, &offset) != ERX_DRAW_OK) {
			if (offset > size - at)
				abort();
			break;
		}
		if (used < 1 || used > size - at)
			abort();
		for (uint8_t i = 0; i < msg.layout->nfields; i++) {
			value = &msg.values[i];
			if (value->data != NULL &&
			    (value->data < data + at + 1 ||
			    value->length > (size_t)(data + at + used - value->data)))
				abort();
		}
	}
	return (0);
}
