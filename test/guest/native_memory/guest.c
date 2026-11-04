/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

/*
 * The memory transcript: a root task that runs the five calls over real pages and
 * reports each case on one line, which tools/lib/erx/native_memory.rb judges. Too
 * few rights show up as a fault, which ends the machine with a crash record before
 * the case's line. A page with too many rights shows only in a touch that must
 * fault: test/guest/native_crash does that.
 */

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#include "erx/abi.h"
#include "liberx/backend/fiasco/console.h"
#include "liberx/backend/fiasco/service.h"
#include "liberx/backend/fiasco/vm.h"

#define PAGE		((uint64_t)ERX_PAGE_SIZE)
/* An address well inside the area and one page below its top: see vm.c's layout. */
#define AREA_MIDDLE	UINT64_C(0x6000000000)
#define AREA_TOP_PAGE	(UINT64_C(0x8000000000) - PAGE)

void erx_fiasco_root_main(void);

static void line_write(const char *);
static void line_write_number(const char *, uint64_t);

static uint64_t
word_at(uint64_t addr)
{
	return (*(volatile uint64_t *)(uintptr_t)addr);
}

static void
word_put(uint64_t addr, uint64_t value)
{
	*(volatile uint64_t *)(uintptr_t)addr = value;
}

/* A word at each end of a page, so a wrong page shows wherever it differs. */
static void
page_fill(uint64_t addr, uint64_t seed)
{
	word_put(addr, seed);
	word_put(addr + PAGE - sizeof(uint64_t), ~seed);
}

static bool
page_holds(uint64_t addr, uint64_t seed)
{
	return (word_at(addr) == seed && word_at(addr + PAGE - sizeof(uint64_t)) == ~seed);
}

static bool
page_is_zero(uint64_t addr)
{
	for (uint64_t offset = 0; offset < PAGE; offset += sizeof(uint64_t))
		if (word_at(addr + offset) != 0)
			return (false);
	return (true);
}

/* Commit, write, decommit, recommit: the page reads zeros, its neighbours do not. */
static bool
case_decommit_recommit_reads_zeros(void)
{
	uint64_t base;
	bool ok;

	if (erx_vm_reserve(0, 3 * PAGE, 0, &base) != 0 || erx_vm_commit(base, 3 * PAGE) != 0)
		return (false);
	for (uint64_t index = 0; index < 3; index++)
		page_fill(base + index * PAGE, 0xa0 + index);
	if (erx_vm_decommit(base + PAGE, PAGE) != 0 || erx_vm_commit(base + PAGE, PAGE) != 0)
		return (false);
	ok = page_holds(base, 0xa0) && page_is_zero(base + PAGE) && page_holds(base + 2 * PAGE, 0xa2);
	return (ok && erx_vm_release(base, 3 * PAGE) == 0);
}

/* No access and back keeps both the page and its contents. */
static bool
case_no_access_and_back_keeps_contents(void)
{
	const uint64_t free_before = erx_fiasco_vm_free_pages();
	uint64_t base;
	bool ok;

	if (erx_vm_reserve(0, PAGE, 0, &base) != 0 || erx_vm_commit(base, PAGE) != 0)
		return (false);
	page_fill(base, 0xb0);
	if (erx_space_protect(base, PAGE, ERX_PROT_NONE) != 0 ||
	    erx_fiasco_vm_free_pages() != free_before - 1 ||
	    erx_space_protect(base, PAGE, ERX_PROT_RW) != 0)
		return (false);
	ok = page_holds(base, 0xb0);
	return (ok && erx_vm_release(base, PAGE) == 0);
}

/* Read-only, then raised to read-write by mapping the same page again. */
static bool
case_read_only_raises_to_read_write(void)
{
	uint64_t base;
	bool ok;

	if (erx_vm_reserve(0, PAGE, 0, &base) != 0 || erx_vm_commit(base, PAGE) != 0)
		return (false);
	page_fill(base, 0xc0);
	if (erx_space_protect(base, PAGE, ERX_PROT_R) != 0 || !page_holds(base, 0xc0) ||
	    erx_space_protect(base, PAGE, ERX_PROT_RW) != 0)
		return (false);
	page_fill(base, 0xc1);
	ok = page_holds(base, 0xc1);
	return (ok && erx_vm_release(base, PAGE) == 0);
}

/*
 * As musl's pthread_create maps a stack: the whole area with no access, then
 * everything above the guard read-write. Only the stack costs pages, and access
 * commits them.
 */
static bool
case_stack_through_no_access(void)
{
	const uint64_t guard = PAGE, stack = 4 * PAGE;
	const uint64_t free_before = erx_fiasco_vm_free_pages();
	uint64_t base;
	bool ok = true;

	if (erx_vm_reserve(0, guard + stack, 0, &base) != 0 ||
	    erx_space_protect(base, guard + stack, ERX_PROT_NONE) != 0 ||
	    erx_fiasco_vm_free_pages() != free_before ||
	    erx_space_protect(base + guard, stack, ERX_PROT_RW) != 0 ||
	    erx_fiasco_vm_free_pages() != free_before - stack / PAGE)
		return (false);
	for (uint64_t offset = guard + stack; offset > guard; offset -= PAGE) {
		ok = ok && page_is_zero(base + offset - PAGE);
		page_fill(base + offset - PAGE, offset);
	}
	for (uint64_t offset = guard + stack; offset > guard; offset -= PAGE)
		ok = ok && page_holds(base + offset - PAGE, offset);
	return (ok && erx_vm_release(base, guard + stack) == 0 &&
	    erx_fiasco_vm_free_pages() == free_before);
}

/*
 * A protect the pool cannot cover changes nothing: its first page stays
 * uncommitted, so committing that page alone costs exactly one.
 */
static bool
case_refused_protect_changes_nothing(void)
{
	const uint64_t free_before = erx_fiasco_vm_free_pages();
	const uint64_t size = (free_before + 1) * PAGE;
	uint64_t base;

	if (erx_vm_reserve(0, size, 0, &base) != 0 ||
	    erx_space_protect(base, size, ERX_PROT_RW) != ERX_ENOMEM ||
	    erx_fiasco_vm_free_pages() != free_before ||
	    erx_vm_commit(base, PAGE) != 0 ||
	    erx_fiasco_vm_free_pages() != free_before - 1)
		return (false);
	return (erx_vm_release(base, size) == 0);
}

/* Write with execute is refused, as is every value that is not a protection. */
static bool
case_write_and_execute_refused(void)
{
	static const uint32_t refused[] = { 2, 4, 6, 7, 8, UINT32_MAX };
	uint64_t base;

	if (erx_vm_reserve(0, PAGE, 0, &base) != 0 || erx_vm_commit(base, PAGE) != 0)
		return (false);
	for (size_t index = 0; index < sizeof(refused) / sizeof(refused[0]); index++)
		if (erx_space_protect(base, PAGE, refused[index]) != ERX_EINVAL)
			return (false);
	page_fill(base, 0xd0);
	return (page_holds(base, 0xd0) && erx_vm_release(base, PAGE) == 0);
}

/* The call table's other refusals, and holes where each call treats them its own way. */
static bool
case_refusals(void)
{
	uint64_t base;
	const uint64_t free_before = erx_fiasco_vm_free_pages();

	if (erx_vm_reserve(0, PAGE, 0, &base) != 0)
		return (false);
	return (erx_vm_commit(base + 1, PAGE) == ERX_EINVAL &&
	    erx_vm_commit(base, 0) == ERX_EINVAL &&
	    erx_vm_commit(PAGE, PAGE) == ERX_ERANGE &&
	    erx_vm_commit(UINT64_MAX - PAGE + 1, PAGE) == ERX_ERANGE &&
	    erx_space_protect(base, 2 * PAGE, ERX_PROT_RW) == ERX_ERANGE &&
	    erx_vm_reserve(base, PAGE, ERX_VM_FIXED | ERX_VM_NOREPLACE, NULL) == ERX_EEXIST &&
	    erx_vm_reserve(base, PAGE, ERX_VM_NOREPLACE, NULL) == ERX_EINVAL &&
	    erx_vm_release(base, PAGE) == 0 && erx_fiasco_vm_free_pages() == free_before);
}

/* A fixed reserve replaces what the range held: its pages return, and it reads zeros. */
static bool
case_fixed_reserve_replaces(void)
{
	const uint64_t free_before = erx_fiasco_vm_free_pages();
	bool ok;

	if (erx_vm_reserve(AREA_MIDDLE, PAGE, ERX_VM_FIXED, NULL) != 0 ||
	    erx_vm_commit(AREA_MIDDLE, PAGE) != 0)
		return (false);
	page_fill(AREA_MIDDLE, 0xe0);
	if (erx_vm_reserve(AREA_MIDDLE, PAGE, ERX_VM_FIXED, NULL) != 0 ||
	    erx_fiasco_vm_free_pages() != free_before ||
	    erx_vm_commit(AREA_MIDDLE, PAGE) != 0)
		return (false);
	ok = page_is_zero(AREA_MIDDLE);
	return (ok && erx_vm_release(AREA_MIDDLE, PAGE) == 0);
}

/* The area's last page is real memory: the layout's limit agrees with the kernel's. */
static bool
case_area_top_page_works(void)
{
	bool ok;

	if (erx_vm_reserve(AREA_TOP_PAGE, PAGE, ERX_VM_FIXED, NULL) != 0 ||
	    erx_vm_commit(AREA_TOP_PAGE, PAGE) != 0)
		return (false);
	page_fill(AREA_TOP_PAGE, 0xf0);
	ok = page_holds(AREA_TOP_PAGE, 0xf0);
	return (ok && erx_vm_release(AREA_TOP_PAGE, PAGE) == 0);
}

/*
 * Each cell of the design's Protection table, over real pages: a committed page
 * from each protection to each other keeps its contents and its one pool page,
 * and an uncommitted page given access costs one page and reads zeros.
 */
static bool
case_every_protection_change(void)
{
	static const uint32_t prots[] = { ERX_PROT_NONE, ERX_PROT_R, ERX_PROT_RW, ERX_PROT_RX };
	const size_t nprots = sizeof(prots) / sizeof(prots[0]);
	const uint64_t free_before = erx_fiasco_vm_free_pages();
	uint64_t base;

	if (erx_vm_reserve(0, PAGE, 0, &base) != 0)
		return (false);
	for (size_t to = 1; to < nprots; to++) {
		if (erx_space_protect(base, PAGE, prots[to]) != 0 || !page_is_zero(base) ||
		    erx_fiasco_vm_free_pages() != free_before - 1 ||
		    erx_vm_decommit(base, PAGE) != 0 || erx_fiasco_vm_free_pages() != free_before)
			return (false);
	}
	if (erx_vm_commit(base, PAGE) != 0)
		return (false);
	for (size_t from = 0; from < nprots; from++) {
		for (size_t to = 0; to < nprots; to++) {
			const uint64_t seed = 0x100 + from * 16 + to;

			if (erx_space_protect(base, PAGE, ERX_PROT_RW) != 0)
				return (false);
			page_fill(base, seed);
			if (erx_space_protect(base, PAGE, prots[from]) != 0 ||
			    erx_space_protect(base, PAGE, prots[to]) != 0 ||
			    erx_fiasco_vm_free_pages() != free_before - 1)
				return (false);
			if (prots[to] == ERX_PROT_NONE && erx_space_protect(base, PAGE, ERX_PROT_R) != 0)
				return (false);
			if (!page_holds(base, seed))
				return (false);
		}
	}
	return (erx_vm_release(base, PAGE) == 0 && erx_fiasco_vm_free_pages() == free_before);
}

/* The whole pool at once: the index at its fullest, and Fiasco's own memory. */
static bool
case_whole_pool_commits(void)
{
	const uint64_t free_before = erx_fiasco_vm_free_pages();
	const uint64_t size = free_before * PAGE;
	uint64_t base;
	bool ok;

	if (erx_vm_reserve(0, size, 0, &base) != 0 || erx_vm_commit(base, size) != 0 ||
	    erx_fiasco_vm_free_pages() != 0)
		return (false);
	page_fill(base, 0x51);
	page_fill(base + size - PAGE, 0x52);
	ok = page_holds(base, 0x51) && page_holds(base + size - PAGE, 0x52);
	return (ok && erx_vm_release(base, size) == 0 && erx_fiasco_vm_free_pages() == free_before);
}

static void
report(const char *name, bool ok)
{
	line_write("erx: memory: ");
	line_write(name);
	line_write(ok ? " ok\n" : " FAILED\n");
}

void
erx_fiasco_root_main(void)
{
	const char *reason;
	uint64_t free_before;

	reason = erx_fiasco_root_up(NULL, 0);
	if (reason != NULL) {
		line_write("erx: memory: init FAILED: ");
		line_write(reason);
		line_write("\n");
		erx_fiasco_machine_off();
	}
	free_before = erx_fiasco_vm_free_pages();
	line_write_number("erx: memory: pool before ", free_before);

	report("decommit_recommit_reads_zeros", case_decommit_recommit_reads_zeros());
	report("no_access_and_back_keeps_contents", case_no_access_and_back_keeps_contents());
	report("read_only_raises_to_read_write", case_read_only_raises_to_read_write());
	report("stack_through_no_access", case_stack_through_no_access());
	report("refused_protect_changes_nothing", case_refused_protect_changes_nothing());
	report("write_and_execute_refused", case_write_and_execute_refused());
	report("refusals", case_refusals());
	report("fixed_reserve_replaces", case_fixed_reserve_replaces());
	report("area_top_page_works", case_area_top_page_works());
	report("every_protection_change", case_every_protection_change());
	report("whole_pool_commits", case_whole_pool_commits());

	line_write_number("erx: memory: pool after ", erx_fiasco_vm_free_pages());
	report("pool_count_steady", erx_fiasco_vm_free_pages() == free_before);
	line_write("erx: memory: done\n");
	erx_fiasco_machine_off();
}

static void
line_write(const char *text)
{
	size_t length = 0;

	while (text[length] != '\0')
		length++;
	erx_fiasco_console_write(text, length);
}

static void
line_write_number(const char *words, uint64_t value)
{
	char digits[21];
	size_t place = sizeof(digits) - 1;

	digits[place] = '\0';
	do {
		digits[--place] = (char)('0' + value % 10);
		value /= 10;
	} while (value != 0);
	line_write(words);
	line_write(&digits[place]);
	line_write("\n");
}
