/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

/*
 * One fault of a root thread, chosen by ERX_CRASH_CASE at build time, after the
 * line that says where it will land. tools/lib/erx/native_crash.rb reads the crash
 * frame the service prints and holds it to that line. Any line after the touch is
 * a failure: the access was not caught.
 */

#include <stdatomic.h>
#include <stdint.h>

#include "erx/abi.h"
#include "liberx/backend/fiasco/console.h"
#include "liberx/backend/fiasco/service.h"
#include "liberx/backend/fiasco/thread.h"
#include "liberx/backend/fiasco/umtx.h"
#include "liberx/backend/fiasco/vm.h"

#define CASE_DECOMMITTED	1
#define CASE_READ_ONLY_WRITE	2
#define CASE_OTHER_THREAD	3
#define CASE_TRAP		4

#define PAGE		((uint64_t)ERX_PAGE_SIZE)
#define HELPER_STACK	16384

void erx_fiasco_root_main(void);

#if ERX_CRASH_CASE == CASE_OTHER_THREAD
static _Alignas(16) uint8_t helper_stack[HELPER_STACK];
static _Atomic uint32_t never;
#endif

static void
say(const char *text)
{
	size_t length = 0;

	while (text[length] != '\0')
		length++;
	erx_fiasco_console_write(text, length);
}

/* The address the record must carry, as a whole line. */
static void
say_address(uint64_t addr)
{
	static const char digits[] = "0123456789abcdef";
	char line[] = "erx: crash: address 0000000000000000\n";

	for (int digit = 0; digit < 16; digit++)
		line[20 + digit] = digits[(addr >> (60 - 4 * digit)) & 0xf];
	say(line);
}

static uint64_t
reserved_page(void)
{
	uint64_t page;

	if (erx_vm_reserve(ERX_CAP_SELF, 0, PAGE, 0, &page) != ERX_OK)
		say("erx: crash: reserve FAILED\n");
	return (page);
}

#if ERX_CRASH_CASE == CASE_OTHER_THREAD
static void
helper(uint64_t addr)
{
	(void)*(volatile uint64_t *)(uintptr_t)addr;
	say("erx: crash: UNCAUGHT\n");
	erx_fiasco_sleep_forever();
}
#endif

void
erx_fiasco_root_main(void)
{
	const char *reason = erx_fiasco_root_up(NULL, 0);
	uint64_t page;

	if (reason != NULL) {
		say(reason);
		erx_fiasco_machine_off();
	}
	page = reserved_page();
	if (erx_vm_commit(ERX_CAP_SELF, page, PAGE) != ERX_OK)
		say("erx: crash: commit FAILED\n");
	*(volatile uint64_t *)(uintptr_t)page = 1;

#if ERX_CRASH_CASE == CASE_DECOMMITTED
	if (erx_vm_decommit(ERX_CAP_SELF, page, PAGE) != ERX_OK)
		say("erx: crash: decommit FAILED\n");
	say_address(page);
	(void)*(volatile uint64_t *)(uintptr_t)page;
#elif ERX_CRASH_CASE == CASE_READ_ONLY_WRITE
	if (erx_space_protect(ERX_CAP_SELF, page, PAGE, ERX_PROT_R) != ERX_OK)
		say("erx: crash: protect FAILED\n");
	if (*(volatile uint64_t *)(uintptr_t)page != 1)
		say("erx: crash: read-only contents FAILED\n");
	say_address(page);
	*(volatile uint64_t *)(uintptr_t)page = 2;
#elif ERX_CRASH_CASE == CASE_OTHER_THREAD
	{
		erx_fiasco_start_t start = { 0 };
		const uint64_t *const words = (const uint64_t *)(const void *)&start;
		erx_utcb_t *const utcb = erx_utcb_self();
		uint64_t thread;

		if (erx_vm_decommit(ERX_CAP_SELF, page, PAGE) != ERX_OK)
			say("erx: crash: decommit FAILED\n");
		start.regs.gpr[0] = page;
		start.regs.sp = (uint64_t)(uintptr_t)(helper_stack + sizeof(helper_stack));
		start.regs.pc = (uint64_t)(uintptr_t)helper;
		for (size_t word = 0; word < sizeof(start) / sizeof(uint64_t); word++)
			atomic_store_explicit(&utcb->mr[word], words[word], memory_order_relaxed);
		say_address(page);
		if (erx_thread_create(0, 0, 0, 0, &thread) != ERX_OK || erx_thread_start(thread) != ERX_OK)
			say("erx: crash: thread FAILED\n");
		(void)erx_umtx_wait((uint64_t)(uintptr_t)&never, 0, ERX_FIASCO_UMTX_FOREVER);
	}
#elif ERX_CRASH_CASE == CASE_TRAP
	say_address(0);
	__builtin_trap();
#else
#error "ERX_CRASH_CASE names no case"
#endif
	say("erx: crash: UNCAUGHT\n");
	erx_fiasco_sleep_forever();
}
