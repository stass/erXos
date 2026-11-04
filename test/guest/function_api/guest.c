/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

/*
 * The function-API set as native Fiasco's root task: this harness brings the root's
 * service up and gives the set a console; the set itself reads nothing of Fiasco.
 */

#include <stddef.h>

#include "liberx/backend/fiasco/console.h"
#include "liberx/backend/fiasco/group.h"
#include "liberx/backend/fiasco/service.h"
#include "test/guest/function_api/cases.h"

void erx_fiasco_root_main(void);

static uint64_t group;

void
function_api_say(const char *text)
{
	size_t length = 0;

	while (text[length] != '\0')
		length++;
	erx_fiasco_console_write(text, length);
}

uint64_t
function_api_group(void)
{
	return (group);
}

void
erx_fiasco_root_main(void)
{
	const char *const reason = erx_fiasco_root_up(NULL, 0);

	if (reason != NULL) {
		function_api_say("erx: function-api: init FAILED: ");
		function_api_say(reason);
		function_api_say("\n");
		erx_fiasco_machine_off();
	}
	if (erx_group_create(0, 0, &group) != ERX_OK) {
		function_api_say("erx: function-api: init FAILED: no group\n");
		erx_fiasco_machine_off();
	}
	function_api_say("erx: function-api: service up\n");
	function_api_run(function_api_irq_cases, function_api_irq_case_count);
	erx_fiasco_machine_off();
}
