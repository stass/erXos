/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

/*
 * The function-API set in a macOS process, on liberx's hosted backend. It runs the
 * IRQ cases too. The alarm is the run's deadline: a stall kills it, whatever a case's
 * own patience would have allowed.
 */

#include <stdbool.h>
#include <stdint.h>
#include <string.h>
#include <unistd.h>

#include "erx/abi.h"
#include "liberx/backend/api.h"
#include "test/guest/function_api/cases.h"

#define RUN_SECONDS	600u

void
function_api_say(const char *text)
{
	(void)write(STDOUT_FILENO, text, strlen(text));
}

uint64_t
function_api_group(void)
{
	return (ERX_CAP_SELF);
}

/* No devices: a well-formed request is refused, so nothing here can make up an address. */
static bool
case_mem_device_refused(void)
{
	uint64_t mem, addr;

	return (erx_mem_create_physical(0, 0, ERX_PAGE_SIZE, ERX_PAGE_SIZE, ERX_MEM_ATTR_DEVICE, &mem) == ERX_ENOTSUP &&
	    erx_mem_create_contiguous(0, 0, ERX_PAGE_SIZE, 0, &mem) == ERX_ENOTSUP && erx_mem_dma_addr(0, 0, &addr) == ERX_EINVAL);
}

static const function_api_case_t hosted_device_cases[] = {
	{ "mem_device_refused", case_mem_device_refused },
};

int
main(void)
{
	(void)alarm(RUN_SECONDS);
	function_api_run(function_api_hosted_irq_cases, function_api_hosted_irq_case_count, hosted_device_cases,
	    sizeof(hosted_device_cases) / sizeof(hosted_device_cases[0]));
	return (1);
}
