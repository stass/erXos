/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

#ifndef ERX_CBMC_HARNESS_H
#define ERX_CBMC_HARNESS_H

/*
 * What every CBMC harness of test/cbmc shares. A harness includes the
 * core's .c file after this header, so it reaches the core's static
 * helpers as well as its exported functions; CBMC is the only compiler
 * that ever builds a harness, and tools/lib/erx/cbmc.rb runs each with the
 * entry point harness() and the checks its roster entry names.
 *
 * A function CBMC sees declared but never defined returns a fresh
 * nondeterministic value on every call: these are the harnesses' inputs.
 */

#include <stdbool.h>
#include <stdint.h>

uint64_t	nondet_u64(void);
int64_t		nondet_i64(void);
int32_t		nondet_i32(void);
uint32_t	nondet_u32(void);
bool		nondet_bool(void);

/*
 * A trap is a kernel bug, so every trap a harness reaches fails a
 * property. CBMC has no body for __builtin_trap, which the runner reports
 * as a tool error; the macro replaces each call in the core the harness
 * includes, and the assumption ends the path as the trap would.
 */
#define __builtin_trap()						\
	do {							\
		__CPROVER_assert(0, "no kernel trap is reached");	\
		__CPROVER_assume(0);					\
	} while (0)

#endif /* ERX_CBMC_HARNESS_H */
