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
#include "liberx/backend/fiasco/task_start.h"

/* main's stack. ERTS's main thread starts the schedulers and then waits. */
#define MAIN_STACK_BYTES	(1024u * 1024u)
#define MAIN_STACK_GUARD_BYTES	ERX_PAGE_SIZE

/* In root_start.S: runs entry on the stack that ends at top, and never returns. */
_Noreturn void	erx_fiasco_call_on_stack(void *top, void (*entry)(void));

static void	root_enter(void);
static uint64_t	main_stack_alloc_or_machine_off(void);

/*
 * The program to run and its CPU feature words, kept here because erx_fiasco_call_on_stack
 * passes its entry no argument: root_enter reads them after the switch to main's stack.
 */
static int (*root_program)(int, char **, char **);
static erx_fiasco_cpu_features_t root_features;

void
erx_fiasco_libc_root_start(int (*program)(int, char **, char **), erx_fiasco_cpu_features_t features)
{
	root_program = program;
	root_features = features;
	erx_fiasco_call_on_stack((void *)(uintptr_t)main_stack_alloc_or_machine_off(), root_enter);
}

/*
 * Returns the top of main's new stack, or ends the machine when memory for it cannot
 * be had. A reserved page that nothing commits lies below the stack, so an overrun faults.
 */
static uint64_t
main_stack_alloc_or_machine_off(void)
{
	static const char refused[] = "erx: root task: no memory for main's stack\n";
	uint64_t base;

	if (erx_vm_reserve(ERX_CAP_SELF, 0, MAIN_STACK_GUARD_BYTES + MAIN_STACK_BYTES, 0, &base) != ERX_OK ||
	    erx_vm_commit(ERX_CAP_SELF, base + MAIN_STACK_GUARD_BYTES, MAIN_STACK_BYTES) != ERX_OK) {
		erx_fiasco_console_write(refused, sizeof(refused) - 1);
		erx_fiasco_machine_off();
	}
	return (base + MAIN_STACK_GUARD_BYTES + MAIN_STACK_BYTES);
}

static void
root_enter(void)
{
	static const char refused[] = "erx: root task: the generator refused AT_RANDOM's bytes\n";

	if (erx_fiasco_libc_start(root_program, root_features) == ERX_FIASCO_TASK_STATUS_ENTROPY)
		erx_fiasco_console_write(refused, sizeof(refused) - 1);
	erx_fiasco_machine_off();
}
