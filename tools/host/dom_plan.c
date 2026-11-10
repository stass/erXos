/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

/*
 * The manifest check's host run of the domain library's planner
 * (docs/design-system.md, "The manifest", property 12). It builds the
 * library's view of a machine just booted with erx_dom_view_build, from the
 * packed manifest's bytes as the root does (liberx/system/dom_boot_view.c),
 * so every principal passes erx_dom_principal_check here or the build
 * fails. Then it plans each configured domain with erx_dom_plan_configured
 * in boot order and each introduction with erx_dom_plan_connect, and
 * records every plan it makes in the view with erx_dom_plan_record or
 * erx_dom_link_record before planning the next, as the boot does once each
 * plan is applied. So what the library counts across domains (the
 * principals' quotas and budgets, the service grants against system's
 * reserve, the connection rows and each domain's connections quota) is the
 * library's own judgment, and a manifest it would refuse fails the build,
 * not the boot.
 *
 *   dom-plan MANIFEST HEADS PLAN
 *
 * MANIFEST is the packed manifest. PLAN is a text file the check writes,
 * one record per line, every value a decimal integer: the file lines in
 * archive order, then the order lines, then the introduce lines.
 *
 *   file KIND FLAGS HEAD_LEN
 *   order ROW
 *   introduce PLACE PLACE
 *
 * A file line is one archive entry; HEAD_LEN bytes of HEADS, taken in
 * order, are what the archive will hold at the entry's start (an image's
 * manifest), which erx_dom_boot_image judges as the boot does. The order
 * lines give every configured row once, in boot order, and the domain at
 * place n (from 0) has id ERX_DOM_SYSTEM_ID + 1 + n. An introduce line
 * names two places; each party reads a side of its own profile's lane
 * size, as the boot sizes it.
 *
 * It prints `domain N STATUS` for each order line and then `introduce N
 * STATUS` for each introduce line, N its place among its kind from 0 and
 * STATUS erx_status_t's value, and exits 0; a plan refused is not
 * recorded, and the planning goes on. A view the library refuses prints
 * `refused REASON` alone and exits 0. A malformed input prints nothing and
 * exits 2.
 */

#include <errno.h>
#include <inttypes.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "erx/abi.h"
#include "erx/abi_reader.h"
#include "erx/dom.h"
#include "erx/dom_lib.h"
#include "input.h"

#define DOM_PLAN_ROWS_MAX	65536u	/* each table's bound, the manifest's */
#define DOM_PLAN_WORDS_MAX	4u	/* the longest line's words */

/* An introduction: two places in boot order, from 0. */
typedef struct dom_plan_pair {
	uint32_t	a, b;
} dom_plan_pair_t;

/* One line split into its words: the keyword and up to three numbers. */
typedef struct dom_plan_line {
	const char	*keyword;
	uint64_t	 values[DOM_PLAN_WORDS_MAX];
	uint32_t	 count;
	uint32_t	 used;
} dom_plan_line_t;

/* What the plan file gives: each file with its head's length, the boot order and the introductions. */
typedef struct dom_plan_input {
	erx_dom_file_t	*files;
	uint32_t	*head_lens;
	uint32_t	 nfiles, file_room, head_room;
	uint32_t	*order;
	uint32_t	 norder, order_room;
	dom_plan_pair_t	*pairs;
	uint32_t	 npairs, pair_room;
} dom_plan_input_t;

static bool	dom_plan_split(char *, dom_plan_line_t *);
static bool	dom_plan_take(dom_plan_line_t *, uint64_t max, uint64_t *);
static bool	dom_plan_u32(dom_plan_line_t *, uint32_t *);
static bool	dom_plan_grow(void **, uint32_t *, uint32_t *, size_t);
static bool	dom_plan_read(char *, size_t, dom_plan_input_t *);
static bool	dom_plan_line(dom_plan_line_t *, uint32_t *stage, dom_plan_input_t *);


/* Splits a NUL-ended line into its keyword and numbers. */
static bool
dom_plan_split(char *text, dom_plan_line_t *line)
{
	char *word, *end, *rest = text;

	memset(line, 0, sizeof(*line));
	if ((line->keyword = strtok_r(rest, " ", &rest)) == NULL)
		return (false);
	while ((word = strtok_r(NULL, " ", &rest)) != NULL) {
		if (line->count == DOM_PLAN_WORDS_MAX || word[0] < '0' ||
		    word[0] > '9')
			return (false);
		errno = 0;
		line->values[line->count] = strtoull(word, &end, 10);
		if (errno != 0 || *end != '\0')
			return (false);
		line->count++;
	}
	return (true);
}

static bool
dom_plan_take(dom_plan_line_t *line, uint64_t max, uint64_t *value)
{
	if (line->used == line->count || line->values[line->used] > max)
		return (false);
	*value = line->values[line->used++];
	return (true);
}

static bool
dom_plan_u32(dom_plan_line_t *line, uint32_t *value)
{
	uint64_t wide;

	if (!dom_plan_take(line, UINT32_MAX, &wide))
		return (false);
	*value = (uint32_t)wide;
	return (true);
}

/* Makes room for one more row of size bytes, within DOM_PLAN_ROWS_MAX. */
static bool
dom_plan_grow(void **rows, uint32_t *count, uint32_t *room, size_t size)
{
	void *grown;
	uint32_t next;

	if (*count < *room)
		return (true);
	if (*room == DOM_PLAN_ROWS_MAX)
		return (false);
	next = *room == 0 ? 16 : *room * 2;
	if ((grown = realloc(*rows, (size_t)next * size)) == NULL)
		return (false);
	*rows = grown;
	*room = next;
	return (true);
}


/* Takes one line of the plan file; stage keeps the file, order and introduce lines in that order. */
static bool
dom_plan_line(dom_plan_line_t *line, uint32_t *stage, dom_plan_input_t *in)
{
	erx_dom_file_t *file;
	dom_plan_pair_t *pair;
	uint32_t kind, flags;

	if (strcmp(line->keyword, "file") == 0 && *stage == 0) {
		if (!dom_plan_grow((void **)&in->files, &in->nfiles, &in->file_room, sizeof(*in->files)) ||
		    !dom_plan_grow((void **)&in->head_lens, &in->nfiles, &in->head_room, sizeof(*in->head_lens)))
			return (false);
		file = &in->files[in->nfiles];
		*file = (erx_dom_file_t){ 0 };
		if (!dom_plan_u32(line, &kind) || kind > UINT8_MAX ||
		    !dom_plan_u32(line, &flags) || flags > UINT8_MAX ||
		    !dom_plan_u32(line, &in->head_lens[in->nfiles]))
			return (false);
		file->kind = (uint8_t)kind;
		file->flags = (uint8_t)flags;
		in->nfiles++;
	} else if (strcmp(line->keyword, "order") == 0 && *stage <= 1) {
		*stage = 1;
		if (!dom_plan_grow((void **)&in->order, &in->norder, &in->order_room, sizeof(*in->order)) ||
		    !dom_plan_u32(line, &in->order[in->norder]))
			return (false);
		in->norder++;
	} else if (strcmp(line->keyword, "introduce") == 0) {
		*stage = 2;
		if (!dom_plan_grow((void **)&in->pairs, &in->npairs, &in->pair_room, sizeof(*in->pairs)))
			return (false);
		pair = &in->pairs[in->npairs++];
		if (!dom_plan_u32(line, &pair->a) || !dom_plan_u32(line, &pair->b))
			return (false);
	} else
		return (false);
	return (line->used == line->count);
}

/* Reads the plan file's text, every line ended by a newline. */
static bool
dom_plan_read(char *text, size_t length, dom_plan_input_t *in)
{
	dom_plan_line_t line;
	char *cursor, *end, *next;
	uint32_t stage = 0;

	if (memchr(text, '\0', length) != NULL || (length != 0 && text[length - 1] != '\n'))
		return (false);
	for (cursor = text, end = text + length; cursor < end; cursor = next) {
		next = memchr(cursor, '\n', (size_t)(end - cursor));
		*next++ = '\0';
		if (!dom_plan_split(cursor, &line) || !dom_plan_line(&line, &stage, in))
			return (false);
	}
	return (true);
}

int
main(int argc, char **argv)
{
	static erx_dom_lib_t lib;
	static erx_dom_plan_t plan;
	dom_plan_input_t in = { 0 };
	erx_manifest_view_t manifest;
	erx_abi_error_t error;
	erx_dom_boot_sizes_t sizes;
	erx_dom_boot_tables_t tables;
	erx_dom_link_plan_t link;
	erx_status_t status;
	const char *reason;
	uint8_t *bytes, *heads, *region;
	bool *planned;
	char *text;
	size_t length, heads_len, text_len, used = 0, region_len;
	uint32_t row, a, b;

	if (argc != 4 || (bytes = erx_host_input_read(argv[1], &length)) == NULL ||
	    !erx_manifest_open(bytes, length, &manifest, &error) ||
	    (heads = erx_host_input_read(argv[2], &heads_len)) == NULL ||
	    (text = (char *)erx_host_input_read(argv[3], &text_len)) == NULL ||
	    !dom_plan_read(text, text_len, &in))
		return (2);

	/* The tables in one page-aligned region, as the root lays them out. */
	sizes = erx_dom_view_sizes(&manifest, in.nfiles);
	if (!erx_dom_boot_layout(&sizes, 0, &tables, &region_len) ||
	    region_len > SIZE_MAX - 2 * ERX_PAGE_SIZE)
		return (2);
	region_len = (region_len + 2 * ERX_PAGE_SIZE - 1) / ERX_PAGE_SIZE * ERX_PAGE_SIZE;
	if ((region = aligned_alloc(ERX_PAGE_SIZE, region_len)) == NULL ||
	    !erx_dom_boot_layout(&sizes, (uintptr_t)region, &tables, &region_len))
		return (2);
	memset(region, 0, region_len);

	/* Each file judged from its head, the heads consumed in order and all of them. */
	for (uint32_t index = 0; index < in.nfiles; index++) {
		if (in.head_lens[index] > heads_len - used)
			return (2);
		tables.files[index] = in.files[index];
		erx_dom_boot_image(&tables.files[index], heads + used, in.head_lens[index]);
		used += in.head_lens[index];
	}
	if (used != heads_len)
		return (2);
	if ((reason = erx_dom_view_build(&lib, &manifest, in.nfiles, &tables)) != NULL) {
		printf("refused %s\n", reason);
		return (fflush(stdout) == 0 ? 0 : 2);
	}

	/* The order lines name every configured row once. */
	if (in.norder != lib.view.nconfigured || in.norder > ERX_DOM_ID_MAX - ERX_DOM_SYSTEM_ID ||
	    (planned = calloc((size_t)in.norder + 1, sizeof(*planned))) == NULL)
		return (2);
	for (uint32_t place = 0; place < in.norder; place++) {
		if (in.order[place] >= in.norder || planned[in.order[place]])
			return (2);
		planned[in.order[place]] = true;
	}
	for (uint32_t index = 0; index < in.npairs; index++)
		if (in.pairs[index].a >= in.norder || in.pairs[index].b >= in.norder)
			return (2);

	for (uint32_t place = 0; place < in.norder; place++) {
		row = in.order[place];
		status = erx_dom_plan_configured(&lib.view, ERX_DOM_SYSTEM_ID + 1 + place, row, ERX_DOM_PID_NONE, &plan);
		if (status == ERX_OK)
			status = erx_dom_plan_record(&lib.view, &plan);
		printf("domain %" PRIu32 " %d\n", place, (int)status);
	}
	for (uint32_t index = 0; index < in.npairs; index++) {
		a = in.pairs[index].a;
		b = in.pairs[index].b;
		status = erx_dom_plan_connect(&lib.view, ERX_DOM_SYSTEM_ID + 1 + a, ERX_DOM_SYSTEM_ID + 1 + b,
		    lib.view.configured[in.order[a]].lane, lib.view.configured[in.order[b]].lane, &link);
		if (status == ERX_OK)
			status = erx_dom_link_record(&lib.view, &link);
		printf("introduce %" PRIu32 " %d\n", index, (int)status);
	}
	return (fflush(stdout) == 0 ? 0 : 2);
}
