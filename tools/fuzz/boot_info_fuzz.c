/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

/*
 * erx_boot_info_read over raw bytes, in a buffer of exactly their size. A page it
 * accepts must keep each string inside the buffer, and must make a vector whose words
 * are the page's, each in the memory the plan asked for.
 */

#include <stddef.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

#include "erx/abi.h"
#include "liberx/backend/core/boot_info.h"

int LLVMFuzzerTestOneInput(const uint8_t *, size_t);

int
LLVMFuzzerTestOneInput(const uint8_t *bytes, size_t length)
{
	erx_boot_view_t view;
	erx_boot_argv_plan_t plan;
	char **argv;
	char *strings;

	if (erx_boot_info_read(bytes, length, &view) != ERX_BOOT_INFO_OK)
		return (0);
	if ((uint64_t)view.info.node_len + view.info.system_connection.peer_node_len + view.info.args_len + view.info.env_len >
	    ERX_BOOT_STRINGS_MAX)
		abort();
	if (view.info.node_len == 0 || (const uint8_t *)view.node < bytes ||
	    (const uint8_t *)view.node + view.info.node_len > bytes + length)
		abort();
	/* A domain pid only beside a peer, and never a pid of the node itself. */
	if (view.info.system_connection.peer_node_len == 0 ?
	    (view.info.system_connection.domain_pid_number | view.info.system_connection.domain_pid_serial) != 0 :
	    view.info.system_connection.peer_node_len == view.info.node_len &&
	    memcmp(view.system_node, view.node, view.info.node_len) == 0)
		abort();
	if (view.info.args_len != 0 && view.args[view.info.args_len - 1] != '\0')
		abort();
	if (view.info.env_len != 0 && view.env[view.info.env_len - 1] != '\0')
		abort();

	plan = erx_boot_argv_plan(&view);
	argv = malloc((plan.argc + 1) * sizeof(*argv));
	strings = malloc(plan.strings);
	if (argv == NULL || strings == NULL)
		abort();
	erx_boot_argv_fill(&view, argv, strings);
	if (plan.argc < 3 || argv[plan.argc] != NULL || strcmp(argv[0], "beam") != 0)
		abort();
	for (size_t at = 0; at < plan.argc; at++) {
		if (argv[at] < strings || argv[at] >= strings + plan.strings || argv[at][0] == '\0')
			abort();
	}
	free(argv);
	free(strings);
	return (0);
}
