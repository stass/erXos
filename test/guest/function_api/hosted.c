/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

/*
 * The function-API set in a macOS process, on liberx's hosted backend. It runs the
 * IRQ cases too. The alarm is the run's deadline: a stall kills it, whatever a case's
 * own patience would have allowed.
 */

#include <stdint.h>
#include <string.h>
#include <unistd.h>

#include "liberx/backend/api.h"
#include "test/guest/function_api/cases.h"

#define RUN_SECONDS	600u

void
function_api_say(const char *text)
{
	(void)write(STDOUT_FILENO, text, strlen(text));
}

int
main(void)
{
	(void)alarm(RUN_SECONDS);
	function_api_run(function_api_irq_cases, function_api_irq_case_count);
	return (1);
}
