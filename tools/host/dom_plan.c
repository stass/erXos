/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

/*
 * The manifest check's host run of the domain library's planner
 * (docs/design-system.md, "The manifest", property 12). Starting from the
 * view of a machine just booted, it plans each configured domain with
 * erx_dom_plan_configured in boot order and then each introduction with
 * erx_dom_plan_connect, and records every plan it makes in the view with
 * erx_dom_plan_record or erx_dom_link_record before planning the next, as
 * the boot does once each plan is applied. So what the library counts
 * across domains (the principals' quotas and budgets, the service grants
 * against system's reserve, the connection rows and each domain's
 * connections quota) is the library's own judgment, and a manifest it
 * would refuse fails the build, not the boot.
 *
 * Its one argument names a text file the packer writes, one record per
 * line, every value a decimal integer, in this order: one machine line,
 * then the principal, file, domain and introduce lines.
 *
 *   machine MAX_DOMAINS MAX_CONNECTIONS SYSTEM_LANE SYSTEM_RESERVE GRANT
 *   principal MEMORY DOMAINS GRANT LIMITS LIMITS
 *   file KIND FLAGS IMAGE_OK IMAGE_FLAGS
 *   domain PRINCIPAL SPACES RELEASE RELEASE_FILES RUNTIME MEMORY OUTER
 *       GRANT GRANT LIMITS LANE CONNECTIONS
 *   introduce DOMAIN DOMAIN
 *
 * A GRANT is erx_share_t's ten fields in layout order and a LIMITS the
 * eleven fields of erx_runtime_limits_t but its reserved word; SPACES is 1
 * for a domain that holds SPACES and 0 otherwise. Principal
 * n (from 1) is the nth principal line. The domain lines come in boot
 * order, and domain line n (from 0) is configured row n, with domain id
 * ERX_DOM_SYSTEM_ID + 1 + n. An introduce line names two domain lines; each
 * party reads a side of its own profile's lane size, as the boot sizes it.
 * It prints `domain N STATUS` for each domain line and then
 * `introduce N STATUS` for each introduce line, N its place among its kind
 * from 0 and STATUS erx_status_t's value, and exits 0; a plan refused is
 * not recorded, and the planning goes on. A malformed input prints nothing
 * and exits 2.
 */

#include <errno.h>
#include <inttypes.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "erx/dom.h"
#include "input.h"

#define DOM_PLAN_ROWS_MAX	65536u	/* each table's bound, the manifest's */
#define DOM_PLAN_WORDS_MAX	64u	/* the longest line's words */

/* An introduction: two domain lines, from 0. */
typedef struct dom_plan_pair {
	uint32_t	a, b;
} dom_plan_pair_t;

/* One line split into its words: the keyword and up to 63 numbers. */
typedef struct dom_plan_line {
	const char	*keyword;
	uint64_t	 values[DOM_PLAN_WORDS_MAX];
	uint32_t	 count;
	uint32_t	 used;
} dom_plan_line_t;

static bool	dom_plan_split(char *, dom_plan_line_t *);
static bool	dom_plan_take(dom_plan_line_t *, uint64_t max, uint64_t *);
static bool	dom_plan_u32(dom_plan_line_t *, uint32_t *);
static bool	dom_plan_grant(dom_plan_line_t *, erx_grant_t *);
static bool	dom_plan_limits(dom_plan_line_t *, erx_runtime_limits_t *);
static bool	dom_plan_grow(void **, uint32_t *, uint32_t *, size_t);

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

static bool
dom_plan_grant(dom_plan_line_t *line, erx_grant_t *grant)
{
	uint32_t base, ceiling, flags;

	memset(grant, 0, sizeof(*grant));
	if (!dom_plan_take(line, UINT64_MAX, &grant->quota_ns) ||
	    !dom_plan_take(line, UINT64_MAX, &grant->period_ns) ||
	    !dom_plan_take(line, UINT64_MAX, &grant->cpuset) ||
	    !dom_plan_u32(line, &grant->capacity_mcpu) ||
	    !dom_plan_u32(line, &grant->capacity_first) ||
	    !dom_plan_u32(line, &grant->slice_us) ||
	    !dom_plan_u32(line, &grant->grace_us) ||
	    !dom_plan_u32(line, &base) || base > UINT8_MAX ||
	    !dom_plan_u32(line, &ceiling) || ceiling > UINT8_MAX ||
	    !dom_plan_u32(line, &flags) || flags > UINT16_MAX)
		return (false);
	grant->base.raw = (uint8_t)base;
	grant->ceiling.raw = (uint8_t)ceiling;
	grant->flags = (erx_group_flags_t)flags;
	return (true);
}

static bool
dom_plan_limits(dom_plan_line_t *line, erx_runtime_limits_t *limits)
{
	memset(limits, 0, sizeof(*limits));
	return (dom_plan_u32(line, &limits->max_frame) &&
	    dom_plan_u32(line, &limits->max_message_heap) &&
	    dom_plan_u32(line, &limits->funnel_depth) &&
	    dom_plan_u32(line, &limits->exports) &&
	    dom_plan_take(line, UINT64_MAX, &limits->tmp) &&
	    dom_plan_take(line, UINT64_MAX, &limits->overlay) &&
	    dom_plan_u32(line, &limits->atoms) &&
	    dom_plan_u32(line, &limits->foreign_atoms) &&
	    dom_plan_u32(line, &limits->processes) &&
	    dom_plan_take(line, UINT64_MAX, &limits->peer_held) &&
	    dom_plan_take(line, UINT64_MAX, &limits->peer_held_total));
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

int
main(int argc, char **argv)
{
	static erx_dom_plan_t plan;
	erx_dom_link_plan_t link;
	erx_dom_principal_t *principals = NULL;
	erx_dom_configured_t *configured = NULL;
	erx_dom_file_t *files = NULL;
	dom_plan_pair_t *pairs = NULL;
	erx_dom_principal_t *principal;
	erx_dom_configured_t *row;
	erx_dom_file_t *file;
	dom_plan_pair_t *pair;
	erx_dom_view_t view;
	dom_plan_line_t line;
	uint32_t nprincipals = 0, nconfigured = 0, nfiles = 0, npairs = 0;
	uint32_t principal_room = 0, configured_room = 0, file_room = 0;
	uint32_t pair_room = 0;
	uint32_t kind, flags, ok, spaces, stage = 0;
	erx_status_t status;
	char *text, *cursor, *end, *next;
	size_t length;
	bool machine = false;

	if (argc != 2 || (text = (char *)erx_host_input_read(argv[1],
	    &length)) == NULL || memchr(text, '\0', length) != NULL ||
	    (length != 0 && text[length - 1] != '\n'))
		return (2);
	memset(&view, 0, sizeof(view));
	/* Every line ends in a newline, which becomes its NUL. */
	for (cursor = text, end = text + length; cursor < end; cursor = next) {
		next = memchr(cursor, '\n', (size_t)(end - cursor));
		*next++ = '\0';
		if (!dom_plan_split(cursor, &line))
			return (2);
		if (strcmp(line.keyword, "machine") == 0 && !machine) {
			machine = true;
			if (!dom_plan_u32(&line, &view.max_domains) ||
			    view.max_domains > DOM_PLAN_ROWS_MAX ||
			    !dom_plan_u32(&line, &view.max_connections) ||
			    view.max_connections > DOM_PLAN_ROWS_MAX ||
			    !dom_plan_u32(&line, &view.system_lane) ||
			    !dom_plan_u32(&line, &view.system_reserve) ||
			    !dom_plan_grant(&line, &view.system_grant))
				return (2);
		} else if (strcmp(line.keyword, "principal") == 0 &&
		    machine && stage <= 1) {
			stage = 1;
			if (!dom_plan_grow((void **)&principals, &nprincipals,
			    &principal_room, sizeof(*principals)))
				return (2);
			principal = &principals[nprincipals];
			memset(principal, 0, sizeof(*principal));
			principal->number = ++nprincipals;
			if (!dom_plan_take(&line, UINT64_MAX, &principal->memory) ||
			    !dom_plan_u32(&line, &principal->domains_max) ||
			    !dom_plan_grant(&line, &principal->share) ||
			    !dom_plan_limits(&line, &principal->default_limits) ||
			    !dom_plan_limits(&line, &principal->ceiling_limits))
				return (2);
		} else if (strcmp(line.keyword, "file") == 0 && machine &&
		    stage <= 2) {
			stage = 2;
			if (!dom_plan_grow((void **)&files, &nfiles, &file_room,
			    sizeof(*files)))
				return (2);
			file = &files[nfiles++];
			memset(file, 0, sizeof(*file));
			if (!dom_plan_u32(&line, &kind) || kind > UINT8_MAX ||
			    !dom_plan_u32(&line, &flags) || flags > UINT8_MAX ||
			    !dom_plan_u32(&line, &ok) || ok > 1 ||
			    !dom_plan_u32(&line, &file->image_flags))
				return (2);
			file->kind = (uint8_t)kind;
			file->flags = (uint8_t)flags;
			file->image_ok = ok != 0;
		} else if (strcmp(line.keyword, "domain") == 0 && machine &&
		    stage <= 3) {
			stage = 3;
			if (!dom_plan_grow((void **)&configured, &nconfigured,
			    &configured_room, sizeof(*configured)))
				return (2);
			row = &configured[nconfigured++];
			memset(row, 0, sizeof(*row));
			if (!dom_plan_u32(&line, &row->principal) ||
			    !dom_plan_u32(&line, &spaces) || spaces > 1 ||
			    !dom_plan_u32(&line, &row->release) ||
			    !dom_plan_u32(&line, &row->release_files) ||
			    !dom_plan_u32(&line, &row->runtime) ||
			    !dom_plan_take(&line, UINT64_MAX, &row->memory) ||
			    !dom_plan_take(&line, UINT64_MAX, &row->outer) ||
			    !dom_plan_grant(&line, &row->grant) ||
			    !dom_plan_grant(&line, &row->spaces) ||
			    !dom_plan_limits(&line, &row->runtime_limits) ||
			    !dom_plan_u32(&line, &row->lane) ||
			    !dom_plan_u32(&line, &row->connections))
				return (2);
			row->flags = spaces != 0 ? ERX_DOM_SPACES : 0;
		} else if (strcmp(line.keyword, "introduce") == 0 && machine) {
			stage = 4;
			if (!dom_plan_grow((void **)&pairs, &npairs, &pair_room,
			    sizeof(*pairs)))
				return (2);
			pair = &pairs[npairs++];
			if (!dom_plan_u32(&line, &pair->a) || pair->a >= nconfigured ||
			    !dom_plan_u32(&line, &pair->b) || pair->b >= nconfigured)
				return (2);
		} else
			return (2);
		if (line.used != line.count)
			return (2);
	}
	if (!machine || nconfigured > ERX_DOM_ID_MAX - ERX_DOM_SYSTEM_ID)
		return (2);

	/*
	 * The machine just booted: every record free, so no service grant is
	 * admitted, and no connection made. One spare entry each keeps a
	 * zero-sized table a valid allocation.
	 */
	view.domains = calloc(view.max_domains + 1, sizeof(*view.domains));
	view.connections = calloc(view.max_connections + 1,
	    sizeof(*view.connections));
	if (view.domains == NULL || view.connections == NULL)
		return (2);
	view.principals = principals;
	view.nprincipals = nprincipals;
	view.files = files;
	view.nfiles = nfiles;
	view.configured = configured;
	view.nconfigured = nconfigured;
	view.next_connection = 1;

	for (uint32_t index = 0; index < nconfigured; index++) {
		status = erx_dom_plan_configured(&view,
		    ERX_DOM_SYSTEM_ID + 1 + index, index, &plan);
		if (status == ERX_OK)
			status = erx_dom_plan_record(&view, &plan);
		printf("domain %" PRIu32 " %d\n", index, (int)status);
	}
	for (uint32_t index = 0; index < npairs; index++) {
		pair = &pairs[index];
		status = erx_dom_plan_connect(&view,
		    ERX_DOM_SYSTEM_ID + 1 + pair->a, ERX_DOM_SYSTEM_ID + 1 + pair->b,
		    configured[pair->a].lane, configured[pair->b].lane, &link);
		if (status == ERX_OK)
			status = erx_dom_link_record(&view, &link);
		printf("introduce %" PRIu32 " %d\n", index, (int)status);
	}
	return (fflush(stdout) == 0 ? 0 : 2);
}
