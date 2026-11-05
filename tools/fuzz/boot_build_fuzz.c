/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

/*
 * erx_boot_info_build over a request cut from raw bytes, on a page of exactly the size the
 * request names. A refusal leaves the page as it was. A page it writes, the reader must
 * accept, with every field and word as asked and nothing written past them.
 */

#include <stddef.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

#include "erx/abi.h"
#include "liberx/backend/core/boot_info.h"

#define ARG_PARTS	2
#define ENV_PARTS	2
#define PAGE_FILL	0xa5

int LLVMFuzzerTestOneInput(const uint8_t *, size_t);

/* The input's first bytes; the node and each part follow, cut to what remains. */
typedef struct {
	uint32_t		domain_id;
	uint32_t		flags;
	uint32_t		pack_flags;
	uint32_t		capacity_mcpu;
	uint64_t		group;
	uint64_t		release_addr;
	uint64_t		cpuset;
	erx_runtime_limits_t	limits;
	uint16_t		page_size;
	uint16_t		node_len;
	uint16_t		arg_len[ARG_PARTS];
	uint16_t		env_len[ENV_PARTS];
} request_t;

static const char *
cut(const uint8_t **cursor, size_t *left, size_t want, size_t *length)
{
	const char *const start = (const char *)*cursor;

	*length = want < *left ? want : *left;
	*cursor += *length;
	*left -= *length;
	return (start);
}

/* Follows one part's words on the page; a last word without a NUL got one. */
static const char *
check_part(const char *at, const erx_boot_words_t *part)
{
	if (part->length == 0)
		return (at);
	if (memcmp(at, part->bytes, part->length) != 0)
		abort();
	at += part->length;
	if (part->bytes[part->length - 1] != '\0' && *at++ != '\0')
		abort();
	return (at);
}

static void
check_the_page(const request_t *request, const erx_boot_inputs_t *inputs, const uint8_t *page, size_t size)
{
	erx_boot_view_t view;
	const char *at;

	if (erx_boot_info_read(page, size, &view) != ERX_BOOT_INFO_OK)
		abort();
	if (view.info.domain_id != request->domain_id || view.info.flags != request->flags ||
	    view.info.pack_flags != request->pack_flags || view.info.capacity_mcpu != request->capacity_mcpu ||
	    view.info.group.raw != request->group || view.info.release_addr != request->release_addr ||
	    view.info.cpuset != request->cpuset ||
	    memcmp(&view.info.limits, &request->limits, sizeof(request->limits)) != 0)
		abort();
	if (view.info.node_len != inputs->node_len || memcmp(view.node, inputs->node, inputs->node_len) != 0)
		abort();
	at = view.args;
	for (size_t part = 0; part < inputs->nargs; part++)
		at = check_part(at, &inputs->args[part]);
	if (at != view.args + view.info.args_len)
		abort();
	at = view.env;
	for (size_t part = 0; part < inputs->nenv; part++)
		at = check_part(at, &inputs->env[part]);
	if (at != view.env + view.info.env_len)
		abort();
	/* The strings lie end to end from the node, and a zeroed page holds the rest. */
	for (size_t off = (size_t)view.info.node_off + view.info.node_len + view.info.args_len + view.info.env_len;
	    off < size; off++) {
		if (page[off] != 0)
			abort();
	}
}

int
LLVMFuzzerTestOneInput(const uint8_t *bytes, size_t length)
{
	erx_boot_words_t args[ARG_PARTS];
	erx_boot_words_t env[ENV_PARTS];
	erx_boot_info_status_t status;
	request_t request;
	const uint8_t *cursor;
	size_t left;
	size_t node_len;
	const char *node;
	uint8_t *page;

	if (length < sizeof(request))
		return (0);
	memcpy(&request, bytes, sizeof(request));
	cursor = bytes + sizeof(request);
	left = length - sizeof(request);
	node = cut(&cursor, &left, request.node_len, &node_len);
	for (size_t part = 0; part < ARG_PARTS; part++)
		args[part].bytes = cut(&cursor, &left, request.arg_len[part], &args[part].length);
	for (size_t part = 0; part < ENV_PARTS; part++)
		env[part].bytes = cut(&cursor, &left, request.env_len[part], &env[part].length);

	const erx_boot_inputs_t inputs = {
		.domain_id = request.domain_id,
		.flags = request.flags,
		.pack_flags = request.pack_flags,
		.capacity_mcpu = request.capacity_mcpu,
		.group = { .raw = request.group },
		.release_addr = request.release_addr,
		.cpuset = request.cpuset,
		.node = node,
		.node_len = node_len,
		.args = args,
		.nargs = ARG_PARTS,
		.env = env,
		.nenv = ENV_PARTS,
		.limits = request.limits,
	};

	page = malloc(request.page_size != 0 ? request.page_size : 1);
	if (page == NULL)
		abort();
	memset(page, PAGE_FILL, request.page_size);
	status = erx_boot_info_build(&inputs, page, request.page_size);
	if (status == ERX_BOOT_INFO_OK) {
		check_the_page(&request, &inputs, page, request.page_size);
	} else {
		if (erx_boot_info_reason(status) == NULL)
			abort();
		for (size_t at = 0; at < request.page_size; at++) {
			if (page[at] != PAGE_FILL)
				abort();
		}
	}
	free(page);
	return (0);
}
