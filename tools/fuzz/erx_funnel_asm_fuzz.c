/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

/*
 * The funnel's frame assembly over a hostile record.  The input is a
 * byte of max_frame (times 64), a byte of grow refusals (bit i refuses
 * the i-th grow), a byte seeding the producer's part sizes, then the
 * record's body: the frame header, control term and payload as the
 * producer wrote them, whatever they are.  The harness plays erx_lane_take
 * over that body, taking each part where the plan says into a buffer of
 * exactly the planned size, and checks that the plan never points outside
 * the buffer, that every step makes progress, and that a whole record
 * holds exactly the body's bytes: all of them when kept, a prefix with
 * its header when discarded, and discarded only for a refused header, a
 * payload past max_frame or a refused grow.
 */

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

#include "erx/abi.h"
#include "erx/funnel.h"
#include "erx/lane.h"

int LLVMFuzzerTestOneInput(const uint8_t *, size_t);

static uint8_t skip[256];

/* The producer's next part size, 1 to 256 bytes. */
static uint32_t
part_size(uint32_t *seed)
{
	*seed ^= *seed << 13;
	*seed ^= *seed >> 17;
	*seed ^= *seed << 5;
	return ((*seed & 0xff) + 1);
}

int
LLVMFuzzerTestOneInput(const uint8_t *data, size_t size)
{
	erx_funnel_asm_t a;
	erx_funnel_asm_plan_t plan;
	erx_funnel_asm_status_t status = ERX_FUNNEL_ASM_MORE;
	erx_funnel_header_t header;
	const uint8_t *body;
	uint8_t *buf;
	size_t cap = ERX_FUNNEL_ASM_FIRST;
	uint32_t len, pos = 0, grows = 0, seed, refusals;
	bool refused = false, sound;

	if (size < 3 || size - 3 < ERX_FRAME_HEADER_SIZE || size - 3 > ERX_FRAME_MAX)
		return (0);
	erx_funnel_asm_init(&a, (uint32_t)data[0] * 64);
	refusals = data[1];
	seed = (uint32_t)data[2] * 2654435761u + 1;
	body = data + 3;
	len = (uint32_t)(size - 3);
	if ((buf = malloc(cap)) == NULL)
		abort();
	/* Each pass copies a byte or more, skips a part, or grows the buffer. */
	for (uint64_t passes = 0; status == ERX_FUNNEL_ASM_MORE; passes++) {
		erx_lane_part_t part = { .len = len, .kind = ERX_REC_FRAME, .opened = pos == 0 };
		uint32_t room;
		uint8_t *into;

		if (passes > 4 * (uint64_t)len + 64)
			abort();
		erx_funnel_asm_plan(&a, cap, &plan);
		if (plan.where == ERX_FUNNEL_ASM_GROW) {
			uint8_t *grown;

			if (plan.want <= cap || plan.want > len)
				abort();
			if (grows < 8 && (refusals & (1u << grows++)) != 0) {
				erx_funnel_asm_ungrown(&a);
				refused = true;
				continue;
			}
			if ((grown = realloc(buf, plan.want)) == NULL)
				abort();
			buf = grown;
			cap = plan.want;
			continue;
		}
		if (plan.where == ERX_FUNNEL_ASM_COPY) {
			if (plan.room == 0 || (size_t)plan.at + plan.room > cap || plan.at != a.held)
				abort();
			into = buf + plan.at;
			room = plan.room;
		} else {
			into = skip;
			room = sizeof(skip);
		}
		part.copied = part_size(&seed);
		if (part.copied > room)
			part.copied = room;
		if (part.copied > len - pos)
			part.copied = len - pos;
		memcpy(into, body + pos, part.copied);
		pos += (uint32_t)part.copied;
		part.closed = pos == len;
		status = erx_funnel_asm_took(&a, &plan, &part, buf);
	}
	if (status != ERX_FUNNEL_ASM_WHOLE || a.frame != len || a.held > len ||
	    memcmp(buf, body, a.held) != 0)
		abort();
	sound = erx_funnel_header(body, len, &header) == ERX_FUNNEL_OK && header.payload_len <= a.max_frame;
	/* Kept whole exactly when the header is sound, the payload within max_frame and no grow refused. */
	if (a.discard == (sound && !refused) || (!a.discard && a.held != len))
		abort();
	if (a.discard) {
		if (!refused && a.held != (len < ERX_FUNNEL_ASM_KEEP ? len : ERX_FUNNEL_ASM_KEEP))
			abort();
	}
	erx_funnel_asm_next(&a);
	if (a.frame != 0 || a.held != 0 || a.sized || a.discard)
		abort();
	free(buf);
	return (0);
}
