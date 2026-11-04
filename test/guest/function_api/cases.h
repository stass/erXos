/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

#ifndef ERX_TEST_FUNCTION_API_CASES_H
#define ERX_TEST_FUNCTION_API_CASES_H

#include <stdatomic.h>
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

/*
 * The function-API test set (docs/design-stopgap.md, "The call table"), which seeds
 * the conformance roster. It reads no backend's identifier, no address a backend
 * chose and no handle's bits; its harness gives it somewhere to print.
 */

typedef struct function_api_case {
	const char	*name;
	bool		(*run)(void);
} function_api_case_t;

/* Writes text where the transcript goes: the harness of each backend has this one job. */
void	function_api_say(const char *text);
/* The group a bind names: making it is its harness's job too, since only native has a call for that. */
uint64_t	function_api_group(void);

/* Runs each set's cases in order, one line each, and ends the machine. */
void	function_api_run(const function_api_case_t *extra, size_t nextra, const function_api_case_t *device, size_t ndevice);

/* The cases helper threads share; irq_cases.c uses them too. */
bool	function_api_wait_for(const void *word, unsigned want);
int	function_api_spawn_executor(void (*entry)(uint64_t), uint64_t arg);
void	function_api_bump_done(void);
extern _Atomic uint32_t function_api_done;

/* The two lists irq_cases.c explains: each backend's harness passes its own to function_api_run. */
extern const function_api_case_t function_api_irq_cases[];
extern const size_t function_api_irq_case_count;
extern const function_api_case_t function_api_hosted_irq_cases[];
extern const size_t function_api_hosted_irq_case_count;

#endif /* ERX_TEST_FUNCTION_API_CASES_H */
