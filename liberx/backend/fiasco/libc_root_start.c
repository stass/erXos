/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

/*
 * musl's start path on a root task: move off the small stack the image starts on, then run
 * the program.
 */

#include <stddef.h>
#include <stdint.h>

#include "erx/abi.h"
#include "liberx/backend/api.h"
#include "liberx/backend/fiasco/console.h"
#include "liberx/backend/fiasco/libc_start.h"
#include "liberx/backend/fiasco/runtime_entry.h"
#include "liberx/backend/fiasco/service.h"

/* main's stack. ERTS's main thread starts the schedulers and then waits. */
#define MAIN_STACK_BYTES	(1024u * 1024u)
#define MAIN_STACK_GUARD_BYTES	ERX_PAGE_SIZE

/* In root_start.S: runs entry on the stack that ends at top, and never returns. */
_Noreturn void	erx_fiasco_call_on_stack(void *top, void (*entry)(void));

static void	root_enter(void);
static uint64_t	main_stack_top(void);

static int (*root_program)(int, char **, char **);

void
erx_fiasco_libc_root_start(int (*program)(int, char **, char **))
{
	root_program = program;
	erx_fiasco_call_on_stack((void *)(uintptr_t)main_stack_top(), root_enter);
}

/* A reserved page that nothing commits lies below the stack, so an overrun faults. */
static uint64_t
main_stack_top(void)
{
	static const char refused[] = "erx: root task: no memory for main's stack\n";
	uint64_t base;

	if (erx_vm_reserve(0, MAIN_STACK_GUARD_BYTES + MAIN_STACK_BYTES, 0, &base) != ERX_OK ||
	    erx_vm_commit(base + MAIN_STACK_GUARD_BYTES, MAIN_STACK_BYTES) != ERX_OK) {
		erx_fiasco_console_write(refused, sizeof(refused) - 1);
		erx_fiasco_machine_off();
	}
	return (base + MAIN_STACK_GUARD_BYTES + MAIN_STACK_BYTES);
}

static void
root_enter(void)
{
	erx_fiasco_libc_start(root_program);
	erx_fiasco_machine_off();
}
