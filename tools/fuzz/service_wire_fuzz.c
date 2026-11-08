/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

/*
 * The root service's decoder, fed what a thread can put on the wire: the gate
 * label's low bits and task, the tag's label and count, and the message words.
 * What it accepts must satisfy every check the bodies rely on. Which tasks are live
 * comes from the input too: a pattern of eight bits repeated over the first
 * FUZZ_TASKS indices, so labels past 64 and past the live tasks both get tried.
 */

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

#include "erx/abi.h"
#include "liberx/backend/fiasco/service_wire.h"

#define WIRE_HEAD_BYTES	(sizeof(uint64_t) + sizeof(int64_t) + sizeof(uint8_t) + sizeof(uint8_t))

#define FUZZ_TASKS	4096u

int LLVMFuzzerTestOneInput(const uint8_t *, size_t);

static uint8_t	fuzz_live_bits;
static uint64_t	fuzz_asked;	/* the last task the decoder asked about, or UINT64_MAX */

static bool
fuzz_live(uint32_t task)
{
	fuzz_asked = task;
	return (task < FUZZ_TASKS && ((fuzz_live_bits >> (task % 8)) & 1) != 0);
}

/* Whether the label names a live task, judged here without the decoder. */
static bool
label_live(uint64_t label)
{
	const uint64_t task = label >> ERX_FIASCO_WIRE_LABEL_SHIFT;

	return (task < FUZZ_TASKS && ((fuzz_live_bits >> (task % 8)) & 1) != 0);
}

int
LLVMFuzzerTestOneInput(const uint8_t *data, size_t size)
{
	uint64_t mr[63] = { 0 };
	erx_fiasco_wire_input_t input = { 0 };
	erx_fiasco_wire_decoded_t decoded;
	int64_t tag_label;

	if (size < WIRE_HEAD_BYTES)
		return (0);
	memcpy(&input.label, data, sizeof(input.label));
	memcpy(&tag_label, data + sizeof(input.label), sizeof(tag_label));
	input.tag_label = tag_label;
	input.words = data[sizeof(input.label) + sizeof(tag_label)] & 0x3f;
	fuzz_live_bits = data[sizeof(input.label) + sizeof(tag_label) + 1];
	fuzz_asked = UINT64_MAX;
	input.task_live = fuzz_live;
	memcpy(mr, data + WIRE_HEAD_BYTES,
	    size - WIRE_HEAD_BYTES < sizeof(mr) ? size - WIRE_HEAD_BYTES : sizeof(mr));
	input.mr = mr;

	decoded = erx_fiasco_wire_decode(&input);
	switch (decoded.kind) {
	case ERX_FIASCO_WIRE_DROP:
		if (label_live(input.label))
			abort();
		break;
	case ERX_FIASCO_WIRE_REQUEST:
		if (!label_live(input.label) || decoded.task != fuzz_asked ||
		    decoded.task != input.label >> ERX_FIASCO_WIRE_LABEL_SHIFT || decoded.caller >= ERX_FIASCO_THREADS_MAX ||
		    decoded.status != ERX_OK || erx_fiasco_wire_words(decoded.call) != input.words ||
		    input.words > ERX_FIASCO_WIRE_WORDS_MAX || decoded.call != tag_label ||
		    decoded.request[0] != decoded.caller ||
		    memcmp(decoded.request, mr, input.words * sizeof(uint64_t)) != 0)
			abort();
		break;
	case ERX_FIASCO_WIRE_REFUSE:
		if (!label_live(input.label) || (decoded.status != ERX_EINVAL && decoded.status != ERX_ENOTSUP))
			abort();
		break;
	case ERX_FIASCO_WIRE_FAULT_PAGE:
		if (!label_live(input.label) || decoded.task != fuzz_asked ||
		    decoded.task != input.label >> ERX_FIASCO_WIRE_LABEL_SHIFT || tag_label != ERX_FIASCO_WIRE_PAGE_FAULT ||
		    input.words != ERX_FIASCO_WIRE_PAGE_FAULT_WORDS)
			abort();
		break;
	case ERX_FIASCO_WIRE_FAULT_EXCEPTION:
		if (!label_live(input.label) || decoded.task != fuzz_asked ||
		    decoded.task != input.label >> ERX_FIASCO_WIRE_LABEL_SHIFT || tag_label != ERX_FIASCO_WIRE_EXCEPTION ||
		    input.words != ERX_FIASCO_WIRE_EXCEPTION_WORDS)
			abort();
		break;
	default:
		abort();
	}
	return (0);
}
