/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

#ifndef ERX_HOSTED_INTERNAL_H
#define ERX_HOSTED_INTERNAL_H

#include <stdatomic.h>
#include <stdbool.h>
#include <stdint.h>

/* What the hosted backend's files share (docs/design-stopgap.md, "The hosted backend"). */

/* Puts one line this backend built, its newline included, on the console, unescaped. */
void	erx_hosted_note(const char *line);

/* Says why on the console and ends the process, as a fault ends the machine natively. */
_Noreturn void	erx_hosted_fatal(const char *why);

/* A semaphore over one word: an up never blocks, and the down is false at the deadline, never before it. */
void	erx_hosted_semaphore_up(_Atomic uint32_t *);
bool	erx_hosted_semaphore_down(_Atomic uint32_t *, uint64_t deadline);

/*
 * The group's slots, for the thread calls: a claim for a new executor, its
 * release once it can no longer run.
 */
uint32_t erx_hosted_executor_claim(void);
void	erx_hosted_executor_release(uint32_t slot);

/*
 * Runs fn(arg) on the stack whose top is sp, storing the caller's stack pointer in
 * *saved_sp. fn never returns, and it goes back only by another switch to *saved_sp.
 */
_Noreturn void	erx_hosted_switch_stack(uint64_t sp, void (*fn)(void *), void *arg, uint64_t *saved_sp);

#endif /* ERX_HOSTED_INTERNAL_H */
