/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

/*
 * The root service's decoder, fed what a thread can put on the wire: the gate
 * label's low bits and task, the tag's label and count, and the message words.
 * What it accepts must satisfy every check the bodies rely on.
 */

#include <stddef.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

#include "erx/abi.h"
#include "liberx/backend/fiasco/service_wire.h"

#define WIRE_HEAD_BYTES	(sizeof(uint64_t) + sizeof(int64_t) + sizeof(uint8_t) + sizeof(uint8_t))

int LLVMFuzzerTestOneInput(const uint8_t *, size_t);

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
	input.live_tasks = data[sizeof(input.label) + sizeof(tag_label) + 1];
	memcpy(mr, data + WIRE_HEAD_BYTES,
	    size - WIRE_HEAD_BYTES < sizeof(mr) ? size - WIRE_HEAD_BYTES : sizeof(mr));
	input.mr = mr;

	decoded = erx_fiasco_wire_decode(&input);
	switch (decoded.kind) {
	case ERX_FIASCO_WIRE_DROP:
		if ((input.label >> ERX_FIASCO_WIRE_LABEL_SHIFT) < input.live_tasks)
			abort();
		break;
	case ERX_FIASCO_WIRE_REQUEST:
		if (decoded.task >= input.live_tasks || decoded.caller >= ERX_FIASCO_THREADS_MAX ||
		    decoded.status != ERX_OK || erx_fiasco_wire_words(decoded.call) != input.words ||
		    input.words > ERX_FIASCO_WIRE_WORDS_MAX || decoded.call != tag_label ||
		    decoded.request[0] != decoded.caller ||
		    memcmp(decoded.request, mr, input.words * sizeof(uint64_t)) != 0)
			abort();
		break;
	case ERX_FIASCO_WIRE_REFUSE:
		if (decoded.status != ERX_EINVAL && decoded.status != ERX_ENOTSUP)
			abort();
		break;
	case ERX_FIASCO_WIRE_FAULT_PAGE:
	case ERX_FIASCO_WIRE_FAULT_EXCEPTION:
		break;
	default:
		abort();
	}
	return (0);
}
