/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

#ifndef LIBERX_PROGRAM_PAGES_H
#define LIBERX_PROGRAM_PAGES_H

/*
 * The program layer's memory (program.h): runs of whole pages it commits
 * from the program's budget with erx_vm_reserve and erx_vm_commit, and
 * mappings of memory objects the handler installed, each at fresh
 * addresses.  The layer calls neither musl's malloc nor its stdio, so
 * every object it keeps (the startup message's copy, a pipe end, a read
 * end's lanes) lives in a run of its own.
 */

#include <stdint.h>

/* bytes rounded up to whole pages, or 0 when the rounding overflows. */
uint64_t	erx_prog_page_round(uint64_t bytes);
/* A run of fresh committed pages covering bytes, or NULL. */
void	*erx_prog_pages_take(uint64_t bytes);
/* Gives back a run erx_prog_pages_take made for bytes, or a mapping erx_prog_object_map made. */
void	 erx_prog_pages_give(const void *run, uint64_t bytes);
/* The first bytes of the memory object mem, mapped at fresh addresses with prot, or NULL. */
void	*erx_prog_object_map(uint64_t mem, uint64_t bytes, uint32_t prot);

#endif /* !LIBERX_PROGRAM_PAGES_H */
