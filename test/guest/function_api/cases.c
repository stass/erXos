/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

/*
 * What both backends must do alike, one line per case, judged by
 * tools/lib/erx/function_api.rb. Natively a fault ends the machine before the case's
 * line, and hosted it ends the process: a missing line is a failure either way.
 * Order matters at the two ends only: pool_count_steady closes the memory cases, and
 * indices_run_out uses up the thread table, so it comes last.
 */

#include <stdatomic.h>
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#include "erx/abi.h"
#include "liberx/backend/api.h"
#include "liberx/backend/core/group_report.h"
#include "test/guest/function_api/cases.h"

#define PAGE		((uint64_t)ERX_PAGE_SIZE)
#define STACK_BYTES	UINT64_C(65536)
#define MANY_THREADS	32u
#define PING_ROUNDS	2000u
#define RACE_ROUNDS	2000u
#define JOIN_ROUNDS	1000u
#define DETACHED_ROUNDS	200u
#define DETACHED_PAGES	16u
#define PARK_ROUNDS	2000u
#define PARK_EXECUTORS	2u
#define NS_PER_MS	UINT64_C(1000000)
#define PATIENCE_NS	(UINT64_C(60000) * NS_PER_MS)
#define TLS_VALUE	UINT64_C(0x5a5a00001234beef)
#define ARG_VALUE	UINT64_C(0x1122334455667788)
/* More than either backend's pool holds, and well inside either's area. */
#define BEYOND_POOL	(UINT64_C(8) * 1024 * 1024 * 1024)

_Atomic uint32_t function_api_done;

static _Atomic uint32_t never;
static uint32_t cpu_count;
static uint32_t cpu_next;
static uint64_t seen_tls, seen_arg, seen_stack;
static _Atomic uint32_t turn;
static _Atomic uint32_t race_word;
static _Atomic uint32_t race_stop;
static _Atomic uint32_t race_stale;
static _Atomic uint32_t memory_failed;
static uint64_t last_stack;

static uint64_t
word_addr(const _Atomic uint32_t *word)
{
	return ((uint64_t)(uintptr_t)word);
}

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

/* A release and a fresh reserve of the same pages: nothing the last holder wrote shows. */
static bool
case_released_pages_read_zeros(void)
{
	uint64_t base, again;

	if (erx_vm_reserve(0, 8 * PAGE, 0, &base) != 0 || erx_vm_commit(base, 8 * PAGE) != 0)
		return (false);
	for (uint64_t index = 0; index < 8; index++)
		page_fill(base + index * PAGE, 0x30 + index);
	if (erx_vm_release(base, 8 * PAGE) != 0 || erx_vm_reserve(base, 8 * PAGE, ERX_VM_FIXED, &again) != 0 ||
	    erx_vm_commit(base, 8 * PAGE) != 0)
		return (false);
	for (uint64_t index = 0; index < 8; index++)
		if (!page_is_zero(base + index * PAGE))
			return (false);
	return (erx_vm_release(base, 8 * PAGE) == 0);
}

/* No access and back keeps both the page and its contents. */
static bool
case_no_access_and_back_keeps_contents(void)
{
	const uint64_t free_before = erx_vm_free_pages();
	uint64_t base;
	bool ok;

	if (erx_vm_reserve(0, PAGE, 0, &base) != 0 || erx_vm_commit(base, PAGE) != 0)
		return (false);
	page_fill(base, 0xb0);
	if (erx_space_protect(base, PAGE, ERX_PROT_NONE) != 0 || erx_vm_free_pages() != free_before - 1 ||
	    erx_space_protect(base, PAGE, ERX_PROT_RW) != 0)
		return (false);
	ok = page_holds(base, 0xb0);
	return (ok && erx_vm_release(base, PAGE) == 0);
}

/* Read-only, then raised to read-write. */
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
	const uint64_t free_before = erx_vm_free_pages();
	uint64_t base;
	bool ok = true;

	if (erx_vm_reserve(0, guard + stack, 0, &base) != 0 ||
	    erx_space_protect(base, guard + stack, ERX_PROT_NONE) != 0 ||
	    erx_vm_free_pages() != free_before ||
	    erx_space_protect(base + guard, stack, ERX_PROT_RW) != 0 ||
	    erx_vm_free_pages() != free_before - stack / PAGE)
		return (false);
	for (uint64_t offset = guard + stack; offset > guard; offset -= PAGE) {
		ok = ok && page_is_zero(base + offset - PAGE);
		page_fill(base + offset - PAGE, offset);
	}
	for (uint64_t offset = guard + stack; offset > guard; offset -= PAGE)
		ok = ok && page_holds(base + offset - PAGE, offset);
	return (ok && erx_vm_release(base, guard + stack) == 0 && erx_vm_free_pages() == free_before);
}

/* A protect the pool cannot cover changes nothing: committing its first page alone costs exactly one. */
static bool
case_refused_protect_changes_nothing(void)
{
	const uint64_t free_before = erx_vm_free_pages();
	uint64_t base;

	if (erx_vm_reserve(0, BEYOND_POOL, 0, &base) != 0 ||
	    erx_space_protect(base, BEYOND_POOL, ERX_PROT_RW) != ERX_ENOMEM ||
	    erx_vm_commit(base, BEYOND_POOL) != ERX_ENOMEM ||
	    erx_vm_free_pages() != free_before ||
	    erx_vm_commit(base, PAGE) != 0 ||
	    erx_vm_free_pages() != free_before - 1)
		return (false);
	return (erx_vm_release(base, BEYOND_POOL) == 0 && erx_vm_free_pages() == free_before);
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
	const uint64_t free_before = erx_vm_free_pages();

	if (erx_vm_reserve(0, PAGE, 0, &base) != 0)
		return (false);
	return (erx_vm_commit(base + 1, PAGE) == ERX_EINVAL &&
	    erx_vm_commit(base, 0) == ERX_EINVAL &&
	    erx_vm_commit(PAGE, PAGE) == ERX_ERANGE &&
	    erx_vm_commit(UINT64_MAX - PAGE + 1, PAGE) == ERX_ERANGE &&
	    erx_space_protect(base, 2 * PAGE, ERX_PROT_RW) == ERX_ERANGE &&
	    erx_vm_reserve(base, PAGE, ERX_VM_FIXED | ERX_VM_NOREPLACE, NULL) == ERX_EEXIST &&
	    erx_vm_reserve(base, PAGE, ERX_VM_NOREPLACE, NULL) == ERX_EINVAL &&
	    erx_vm_release(base, PAGE) == 0 && erx_vm_free_pages() == free_before);
}

/* A fixed reserve replaces what the range held: its pages return, and it reads zeros. */
static bool
case_fixed_reserve_replaces(void)
{
	const uint64_t free_before = erx_vm_free_pages();
	uint64_t base;
	bool ok;

	if (erx_vm_reserve(0, PAGE, 0, &base) != 0 || erx_vm_commit(base, PAGE) != 0)
		return (false);
	page_fill(base, 0xe0);
	if (erx_vm_reserve(base, PAGE, ERX_VM_FIXED, NULL) != 0 || erx_vm_free_pages() != free_before ||
	    erx_vm_commit(base, PAGE) != 0)
		return (false);
	ok = page_is_zero(base);
	return (ok && erx_vm_release(base, PAGE) == 0);
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
	const uint64_t free_before = erx_vm_free_pages();
	uint64_t base;

	if (erx_vm_reserve(0, PAGE, 0, &base) != 0)
		return (false);
	for (size_t to = 1; to < nprots; to++) {
		if (erx_space_protect(base, PAGE, prots[to]) != 0 || !page_is_zero(base) ||
		    erx_vm_free_pages() != free_before - 1 ||
		    erx_vm_decommit(base, PAGE) != 0 || erx_vm_free_pages() != free_before)
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
			    erx_vm_free_pages() != free_before - 1)
				return (false);
			if (prots[to] == ERX_PROT_NONE && erx_space_protect(base, PAGE, ERX_PROT_R) != 0)
				return (false);
			if (!page_holds(base, seed))
				return (false);
		}
	}
	return (erx_vm_release(base, PAGE) == 0 && erx_vm_free_pages() == free_before);
}

/*
 * A range of many pages changes between write and execute as one call, beside
 * another reservation that stays writable: no moment of the change, and no
 * neighbour, may stop it.
 */
static bool
case_many_pages_between_write_and_execute(void)
{
	const uint64_t pages = 32;
	uint64_t base, neighbour;
	bool ok = true;

	if (erx_vm_reserve(0, pages * PAGE, 0, &base) != 0 || erx_vm_commit(base, pages * PAGE) != 0 ||
	    erx_vm_reserve(0, PAGE, 0, &neighbour) != 0 || erx_vm_commit(neighbour, PAGE) != 0)
		return (false);
	page_fill(neighbour, 0x71);
	for (uint64_t index = 0; index < pages; index++)
		page_fill(base + index * PAGE, 0x70 + index);
	if (erx_space_protect(base, pages * PAGE, ERX_PROT_RX) != 0)
		return (false);
	page_fill(neighbour, 0x72);
	for (uint64_t index = 0; index < pages; index++)
		ok = ok && page_holds(base + index * PAGE, 0x70 + index);
	if (erx_space_protect(base, pages * PAGE, ERX_PROT_RW) != 0)
		return (false);
	for (uint64_t index = 0; index < pages; index++)
		ok = ok && page_holds(base + index * PAGE, 0x70 + index);
	page_fill(base, 0x7f);
	ok = ok && page_holds(neighbour, 0x72);
	return (ok && erx_vm_release(neighbour, PAGE) == 0 && erx_vm_release(base, pages * PAGE) == 0);
}

/* The whole pool at once: the index at its fullest. */
static bool
case_whole_pool_commits(void)
{
	const uint64_t free_before = erx_vm_free_pages();
	const uint64_t size = free_before * PAGE;
	uint64_t base;
	bool ok;

	if (erx_vm_reserve(0, size, 0, &base) != 0 || erx_vm_commit(base, size) != 0 || erx_vm_free_pages() != 0)
		return (false);
	page_fill(base, 0x51);
	page_fill(base + size - PAGE, 0x52);
	ok = page_holds(base, 0x51) && page_holds(base + size - PAGE, 0x52);
	return (ok && erx_vm_release(base, size) == 0 && erx_vm_free_pages() == free_before);
}

static uint64_t pool_at_start;

/* Every memory case above gave back what it took. */
static bool
case_pool_count_steady(void)
{
	return (erx_vm_free_pages() == pool_at_start);
}

void
function_api_bump_done(void)
{
	atomic_fetch_add_explicit(&function_api_done, 1, memory_order_release);
	(void)erx_umtx_wake(word_addr(&function_api_done), UINT32_MAX);
}

/* Waits until the word holds want, within the patience every case shares. */
bool
function_api_wait_for(const void *word, unsigned want)
{
	_Atomic uint32_t *const target = (_Atomic uint32_t *)(uintptr_t)word;
	const uint64_t deadline = erx_clock_ns() + PATIENCE_NS;

	for (;;) {
		const uint32_t seen = atomic_load_explicit(target, memory_order_acquire);

		if (seen == want)
			return (true);
		if (erx_clock_ns() >= deadline)
			return (false);
		(void)erx_umtx_wait(word_addr(target), seen, deadline);
	}
}

/* Sleep without the word under test: a deadline on a word nobody wakes. */
static void
settle(uint64_t length_ns)
{
	static _Atomic uint32_t word;

	(void)erx_umtx_wait(word_addr(&word), 0, erx_clock_ns() + length_ns);
}

static _Noreturn void
park_forever(void)
{
	for (;;)
		(void)erx_umtx_wait(word_addr(&never), 0, ERX_WAIT_FOREVER);
}

/* How many CPUs there are, as a mask says: asked of one thread once, which also tests the mask. */
static void
cpus_learn(uint64_t thread)
{
	for (uint32_t cpu = 0; cpu < 64 && erx_thread_set_affinity(thread, UINT64_C(1) << cpu) == ERX_OK; cpu++)
		cpu_count = cpu + 1;
}

/* The thread is created, on its way to its share of the CPUs, and not started. */
static int
create_on(uint64_t stack_top, void (*entry)(uint64_t), uint64_t arg, uint64_t tls, uint64_t thread_class,
    uint64_t *thread)
{
	erx_thread_start_t start = { 0 };
	const uint64_t *const words = (const uint64_t *)(const void *)&start;
	erx_utcb_t *const utcb = erx_utcb_self();
	int status;

	start.regs.gpr[0] = arg;
	start.regs.sp = stack_top;
	start.regs.pc = (uint64_t)(uintptr_t)entry;
	start.tls = tls;
	for (size_t word = 0; word < sizeof(start) / sizeof(uint64_t); word++)
		erx_utcb_mr_store(utcb, word, words[word]);
	status = erx_thread_create(0, 0, 0, thread_class, thread);
	if (status != ERX_OK)
		return (status);
	if (cpu_count == 0)
		cpus_learn(*thread);
	if (cpu_count == 0)
		return (ERX_EINVAL);
	return (erx_thread_set_affinity(*thread, UINT64_C(1) << (cpu_next++ % cpu_count)));
}

/* As above on a stack of its own, as musl would map it, for a thread that never gives it back. */
static int
create_class(void (*entry)(uint64_t), uint64_t arg, uint64_t tls, uint64_t thread_class, uint64_t *thread)
{
	uint64_t base;
	int status;

	status = erx_vm_reserve(0, STACK_BYTES, 0, &base);
	if (status == ERX_OK)
		status = erx_vm_commit(base, STACK_BYTES);
	if (status != ERX_OK)
		return (status);
	last_stack = base;
	return (create_on(base + STACK_BYTES, entry, arg, tls, thread_class, thread));
}

static bool
spawn(void (*entry)(uint64_t), uint64_t arg, uint64_t tls)
{
	uint64_t thread;

	return (create_class(entry, arg, tls, ERX_THREAD_CLASS_WORKER, &thread) == ERX_OK &&
	    erx_thread_start(thread) == ERX_OK);
}

int
function_api_spawn_executor(void (*entry)(uint64_t), uint64_t arg)
{
	uint64_t thread;
	int status = create_class(entry, arg, 0, ERX_THREAD_CLASS_EXECUTOR, &thread);

	return (status == ERX_OK ? erx_thread_start(thread) : status);
}

static void
tls_helper(uint64_t arg)
{
	seen_arg = arg;
	seen_tls = erx_thread_pointer();
	/* The frame's address, which is the real stack's even where a sanitizer moves locals. */
	seen_stack = (uint64_t)(uintptr_t)__builtin_frame_address(0);
	function_api_bump_done();
	park_forever();
}

/* The start record reaches the thread: its argument, its thread pointer, its stack. */
static bool
case_tls_and_arg(void)
{
	atomic_store(&function_api_done, 0);
	if (!spawn(tls_helper, ARG_VALUE, TLS_VALUE) || !function_api_wait_for(&function_api_done, 1))
		return (false);
	return (seen_tls == TLS_VALUE && seen_arg == ARG_VALUE && seen_stack >= last_stack &&
	    seen_stack < last_stack + STACK_BYTES);
}

static void
utcb_helper(uint64_t arg)
{
	erx_utcb_t *const utcb = erx_utcb_self();

	erx_utcb_mr_store(utcb, 0, arg);
	seen_arg = (uint64_t)atomic_load(&utcb->self) == (uint64_t)(uintptr_t)utcb ? 1 : 0;
	function_api_bump_done();
	park_forever();
}

/* Each thread's UTCB holds its own address and is its own: a neighbour's store leaves this one's alone. */
static bool
case_utcb_is_each_threads(void)
{
	erx_utcb_t *const utcb = erx_utcb_self();
	uint64_t thread;

	atomic_store(&function_api_done, 0);
	if (create_class(utcb_helper, 1, 0, ERX_THREAD_CLASS_WORKER, &thread) != ERX_OK)
		return (false);
	/* After the create, whose start record went through these registers. */
	erx_utcb_mr_store(utcb, 0, ARG_VALUE);
	if (erx_thread_start(thread) != ERX_OK || !function_api_wait_for(&function_api_done, 1))
		return (false);
	return (seen_arg == 1 && atomic_load(&utcb->self) == (uint64_t)(uintptr_t)utcb &&
	    atomic_load(&utcb->mr[0]) == ARG_VALUE);
}

static void
idle_helper(uint64_t arg)
{
	(void)arg;
	function_api_bump_done();
	park_forever();
}

static bool
case_double_start_refused(void)
{
	uint64_t thread;

	atomic_store(&function_api_done, 0);
	if (create_class(idle_helper, 0, 0, ERX_THREAD_CLASS_WORKER, &thread) != ERX_OK ||
	    erx_thread_start(thread) != ERX_OK || !function_api_wait_for(&function_api_done, 1))
		return (false);
	return (erx_thread_start(thread) == ERX_EINVAL);
}

/* Handles nothing could have issued, and a class that is none. */
static bool
case_bad_handle_refused(void)
{
	uint64_t thread;

	return (erx_thread_start(UINT64_C(1) << 40) == ERX_EINVAL &&
	    erx_thread_set_clear_word(UINT64_C(1) << 40, 0) == ERX_EINVAL &&
	    erx_thread_set_affinity(UINT64_C(1) << 40, 1) == ERX_EINVAL &&
	    erx_thread_create(0, 0, 0, 2, &thread) == ERX_EINVAL &&
	    erx_thread_create(0, 1, 0, ERX_THREAD_CLASS_WORKER, &thread) == ERX_EINVAL);
}

/* The calls this table refuses, whatever they are handed. */
static bool
case_unsupported_refused(void)
{
	return (erx_thread_stop(0) == ERX_ENOTSUP && erx_thread_read(0) == ERX_ENOTSUP &&
	    erx_thread_write(0) == ERX_ENOTSUP && erx_thread_set_urgency(0, 1) == ERX_ENOTSUP &&
	    erx_irq_route(0, 0) == ERX_ENOTSUP);
}

/* A grant keeps its CPU set and a report gives it back as capacity, with usage not measured. */
static bool
case_group_info_and_configure(void)
{
	const uint64_t group = function_api_group();
	erx_utcb_t *const utcb = erx_utcb_self();
	const erx_share_t grant = { .cpuset = UINT64_C(0x5) };
	const erx_share_t empty = { .cpuset = 0 };
	erx_group_report_t report;
	bool ok = erx_group_info(ERX_CAP_NULL) == ERX_EINVAL && erx_group_configure(ERX_CAP_NULL) == ERX_EINVAL &&
	    erx_group_info(UINT64_C(42)) == ERX_EINVAL && erx_group_configure(UINT64_C(42)) == ERX_EINVAL;

	erx_group_grant_store(utcb, &grant);
	ok = ok && erx_group_configure(group) == ERX_OK && erx_group_info(group) == ERX_OK;
	report = erx_group_report_load(utcb);
	ok = ok && report.cpuset == UINT64_C(0x5) && report.capacity_mcpu == 2000 && report.usage_known == 0 &&
	    report.used_ns == 0;
	/* An empty set changes nothing. */
	erx_group_grant_store(utcb, &empty);
	ok = ok && erx_group_configure(group) == ERX_EINVAL && erx_group_info(group) == ERX_OK;
	report = erx_group_report_load(utcb);
	return (ok && report.cpuset == UINT64_C(0x5));
}

static bool
case_umtx_word_differs(void)
{
	static _Atomic uint32_t word = 1;

	return (erx_umtx_wait(word_addr(&word), 0, ERX_WAIT_FOREVER) == ERX_OK);
}

static bool
case_umtx_past_deadline(void)
{
	static _Atomic uint32_t word;

	return (erx_umtx_wait(word_addr(&word), 0, erx_clock_ns() - 1) == ERX_ETIMEDOUT);
}

/* A timed wait returns no sooner than its deadline, at several lengths. */
static bool
case_umtx_timeout_not_early(void)
{
	static _Atomic uint32_t word;

	for (uint32_t ms = 1; ms <= 16; ms *= 2) {
		const uint64_t deadline = erx_clock_ns() + ms * NS_PER_MS;

		if (erx_umtx_wait(word_addr(&word), 0, deadline) != ERX_ETIMEDOUT || erx_clock_ns() < deadline)
			return (false);
	}
	return (true);
}

static _Atomic uint32_t counted_word;

static void
counted_helper(uint64_t arg)
{
	(void)arg;
	(void)erx_umtx_wait(word_addr(&counted_word), 0, ERX_WAIT_FOREVER);
	function_api_bump_done();
	park_forever();
}

/* A wake with no waiter counts none, and one that reaches its waiter counts it, whenever that waiter got there. */
static bool
case_umtx_wake_counts(void)
{
	const uint64_t deadline = erx_clock_ns() + 10000 * NS_PER_MS;
	int woken = 0;

	if (erx_umtx_wake(word_addr(&counted_word), 1) != 0 || erx_umtx_wake(word_addr(&counted_word), UINT32_MAX) != 0)
		return (false);
	atomic_store(&function_api_done, 0);
	if (!spawn(counted_helper, 0, 0))
		return (false);
	while (woken == 0 && erx_clock_ns() < deadline) {
		woken = erx_umtx_wake(word_addr(&counted_word), 1);
		if (woken == 0)
			settle(NS_PER_MS);
	}
	return (woken == 1 && function_api_wait_for(&function_api_done, 1));
}

static void
ping_helper(uint64_t arg)
{
	(void)arg;
	for (uint32_t round = 0; round < PING_ROUNDS; round++) {
		if (!function_api_wait_for(&turn, 1))
			break;
		atomic_store_explicit(&turn, 0, memory_order_release);
		(void)erx_umtx_wake(word_addr(&turn), 1);
	}
	function_api_bump_done();
	park_forever();
}

/* Turn by turn: one lost wake and the pair stops until the patience runs out. */
static bool
case_umtx_ping_pong(void)
{
	atomic_store(&function_api_done, 0);
	atomic_store(&turn, 0);
	if (!spawn(ping_helper, 0, 0))
		return (false);
	for (uint32_t round = 0; round < PING_ROUNDS; round++) {
		atomic_store_explicit(&turn, 1, memory_order_release);
		(void)erx_umtx_wake(word_addr(&turn), 1);
		if (!function_api_wait_for(&turn, 0))
			return (false);
	}
	return (function_api_wait_for(&function_api_done, 1));
}

/*
 * Waits with deadlines as short as the wakes come, then one with no waker at all:
 * a wake left over would make that one return woken.
 */
static void
race_helper(uint64_t arg)
{
	static _Atomic uint32_t quiet;

	(void)arg;
	for (uint32_t round = 0; round < RACE_ROUNDS; round++)
		(void)erx_umtx_wait(word_addr(&race_word), 0, erx_clock_ns() + (round % 8 + 1) * 10000);
	atomic_store_explicit(&race_stop, 1, memory_order_release);
	if (erx_umtx_wait(word_addr(&quiet), 0, erx_clock_ns() + 5 * NS_PER_MS) != ERX_ETIMEDOUT)
		atomic_store_explicit(&race_stale, 1, memory_order_release);
	function_api_bump_done();
	park_forever();
}

static bool
case_umtx_timeout_races_wake(void)
{
	atomic_store(&function_api_done, 0);
	atomic_store(&race_stop, 0);
	if (!spawn(race_helper, 0, 0))
		return (false);
	while (atomic_load_explicit(&race_stop, memory_order_acquire) == 0)
		(void)erx_umtx_wake(word_addr(&race_word), 1);
	return (function_api_wait_for(&function_api_done, 1) && atomic_load(&race_stale) == 0);
}

static void
memory_helper(uint64_t arg)
{
	uint64_t base;

	(void)arg;
	for (uint32_t round = 0; round < 100; round++) {
		if (erx_vm_reserve(0, PAGE, 0, &base) != ERX_OK || erx_vm_commit(base, PAGE) != ERX_OK) {
			atomic_store(&memory_failed, 1);
			break;
		}
		word_put(base, base);
		if (word_at(base) != base || erx_vm_release(base, PAGE) != ERX_OK) {
			atomic_store(&memory_failed, 1);
			break;
		}
	}
	function_api_bump_done();
	park_forever();
}

/* Two threads call the memory calls at once; the count comes back. Their stacks count first. */
static bool
case_memory_from_threads(void)
{
	uint64_t before;
	uint64_t first, second;

	atomic_store(&function_api_done, 0);
	if (create_class(memory_helper, 0, 0, ERX_THREAD_CLASS_WORKER, &first) != ERX_OK ||
	    create_class(memory_helper, 0, 0, ERX_THREAD_CLASS_WORKER, &second) != ERX_OK)
		return (false);
	before = erx_vm_free_pages();
	if (erx_thread_start(first) != ERX_OK || erx_thread_start(second) != ERX_OK ||
	    !function_api_wait_for(&function_api_done, 2))
		return (false);
	return (atomic_load(&memory_failed) == 0 && erx_vm_free_pages() == before);
}

/*
 * An empty mask and a CPU past any there is are refused and leave the thread ready to
 * start. A mask holding a CPU that exists is taken, whatever else it names.
 */
static bool
case_affinity_refused(void)
{
	uint64_t thread;
	bool ok;

	atomic_store(&function_api_done, 0);
	if (create_class(idle_helper, 0, 0, ERX_THREAD_CLASS_WORKER, &thread) != ERX_OK)
		return (false);
	ok = erx_thread_set_affinity(thread, 0) == ERX_EINVAL &&
	    erx_thread_set_affinity(thread, UINT64_C(1) << 63) == ERX_EINVAL &&
	    erx_thread_set_affinity(thread, UINT64_MAX) == ERX_OK;
	return (ok && erx_thread_start(thread) == ERX_OK && function_api_wait_for(&function_api_done, 1));
}

static _Atomic uint32_t join_word;
static _Atomic uint64_t join_seen;

static void
join_helper(uint64_t arg)
{
	atomic_store_explicit(&join_seen, arg, memory_order_release);
	erx_thread_exit();
}

/*
 * musl's join, without musl: the word holds a nonzero identifier until the backend
 * clears it, and a thread reuses the same stack as soon as it does. The joined
 * handle names no thread.
 */
static bool
case_join_loop(void)
{
	uint64_t base;

	if (erx_vm_reserve(0, STACK_BYTES, 0, &base) != ERX_OK || erx_vm_commit(base, STACK_BYTES) != ERX_OK)
		return (false);
	for (uint32_t round = 0; round < JOIN_ROUNDS; round++) {
		const uint64_t patience = erx_clock_ns() + PATIENCE_NS;
		uint64_t thread;
		int status;

		atomic_store_explicit(&join_word, 1, memory_order_release);
		/* A free index may wait for its kernel to finish with it. */
		while ((status = create_on(base + STACK_BYTES, join_helper, round, 0, ERX_THREAD_CLASS_WORKER,
		    &thread)) == ERX_ENOMEM && erx_clock_ns() < patience)
			settle(NS_PER_MS);
		if (status != ERX_OK || erx_thread_set_clear_word(thread, word_addr(&join_word)) != ERX_OK ||
		    erx_thread_start(thread) != ERX_OK || !function_api_wait_for(&join_word, 0) ||
		    atomic_load_explicit(&join_seen, memory_order_acquire) != round ||
		    erx_thread_start(thread) != ERX_EINVAL)
			return (false);
	}
	return (erx_vm_release(base, STACK_BYTES) == ERX_OK);
}

static _Atomic uint32_t detached_ran;

static void
detached_helper(uint64_t base)
{
	atomic_fetch_add_explicit(&detached_ran, 1, memory_order_release);
	(void)erx_umtx_wake(word_addr(&detached_ran), 1);
	erx_thread_exit_release(base, DETACHED_PAGES * PAGE);
}

/* The backend releases each stack, so the pool's count comes back with no join to wait on. */
static bool
case_detached_loop(void)
{
	const uint64_t before = erx_vm_free_pages();
	const uint64_t deadline = erx_clock_ns() + PATIENCE_NS;
	const uint64_t bytes = DETACHED_PAGES * PAGE;

	atomic_store(&detached_ran, 0);
	for (uint32_t round = 0; round < DETACHED_ROUNDS; round++) {
		uint64_t base, thread;
		int status;

		if (erx_vm_reserve(0, bytes, 0, &base) != ERX_OK || erx_vm_commit(base, bytes) != ERX_OK)
			return (false);
		while ((status = create_on(base + bytes, detached_helper, base, 0, ERX_THREAD_CLASS_WORKER, &thread)) ==
		    ERX_ENOMEM && erx_clock_ns() < deadline)
			settle(NS_PER_MS);
		if (status != ERX_OK || erx_thread_start(thread) != ERX_OK ||
		    !function_api_wait_for(&detached_ran, round + 1))
			return (false);
	}
	while (erx_vm_free_pages() != before) {
		if (erx_clock_ns() >= deadline)
			return (false);
		settle(NS_PER_MS);
	}
	return (true);
}

static bool
case_park_refusals(void)
{
	return (erx_executor_slot() == ERX_NO_EXECUTOR_SLOT && erx_park(0, 0, ERX_WAIT_FOREVER) == ERX_ETYPE &&
	    erx_executor_wake(ERX_GROUP_EXECUTORS_MAX) == ERX_EINVAL &&
	    erx_executor_wake(ERX_GROUP_EXECUTORS_MAX - 1) == ERX_EINVAL);
}

static uint64_t
group_epoch(void)
{
	return (atomic_load_explicit(&erx_group_status()->epoch, memory_order_acquire));
}

static uint64_t
slot_epoch(uint32_t slot)
{
	return (atomic_load_explicit(&erx_group_status()->exec[slot].epoch, memory_order_acquire));
}

static _Atomic uint32_t park_self_ok;

/* An executor alone: either epoch moved since the read returns at once, and a quiet park times out. */
static void
park_self_helper(uint64_t arg)
{
	const uint32_t slot = erx_executor_slot();
	uint64_t group = group_epoch(), epoch = slot_epoch(slot), deadline;
	bool ok;

	(void)arg;
	erx_group_trigger();
	ok = erx_park(group, epoch, ERX_WAIT_FOREVER) == ERX_OK;
	group = group_epoch();
	ok = ok && erx_executor_wake(slot) == ERX_OK;
	ok = ok && erx_park(group, epoch, ERX_WAIT_FOREVER) == ERX_OK;
	group = group_epoch();
	epoch = slot_epoch(slot);
	deadline = erx_clock_ns() + 20 * NS_PER_MS;
	ok = ok && erx_park(group, epoch, deadline) == ERX_ETIMEDOUT && erx_clock_ns() >= deadline;
	ok = ok && atomic_load(&erx_group_status()->parked) == 0;
	ok = ok && atomic_load(&erx_group_status()->exec[slot].state) == ERX_EXEC_STATE_RUNNING;
	atomic_store(&park_self_ok, ok ? 1 : 0);
	function_api_bump_done();
	erx_thread_exit();
}

static bool
case_park_alone(void)
{
	atomic_store(&function_api_done, 0);
	if (function_api_spawn_executor(park_self_helper, 0) != ERX_OK ||
	    !function_api_wait_for(&function_api_done, 1))
		return (false);
	return (atomic_load(&park_self_ok) == 1);
}

static _Atomic uint32_t park_gate_at;
static _Atomic uint32_t park_gate_open;
static _Atomic uint32_t park_gate_ok;

/* The window the protocol exists for: the trigger lands between the empty check and the park. */
static void
park_gate_helper(uint64_t arg)
{
	const uint32_t slot = erx_executor_slot();
	const uint64_t group = group_epoch(), epoch = slot_epoch(slot);

	(void)arg;
	atomic_store_explicit(&park_gate_at, 1, memory_order_release);
	(void)erx_umtx_wake(word_addr(&park_gate_at), 1);
	if (function_api_wait_for(&park_gate_open, 1))
		atomic_store(&park_gate_ok, erx_park(group, epoch, ERX_WAIT_FOREVER) == ERX_OK ? 1 : 0);
	function_api_bump_done();
	erx_thread_exit();
}

static bool
case_park_trigger_in_window(void)
{
	atomic_store(&function_api_done, 0);
	if (function_api_spawn_executor(park_gate_helper, 0) != ERX_OK || !function_api_wait_for(&park_gate_at, 1))
		return (false);
	erx_group_trigger();
	atomic_store_explicit(&park_gate_open, 1, memory_order_release);
	(void)erx_umtx_wake(word_addr(&park_gate_open), 1);
	return (function_api_wait_for(&function_api_done, 1) && atomic_load(&park_gate_ok) == 1);
}

static _Atomic uint32_t park_published;
static _Atomic uint32_t park_consumed;
static _Atomic uint32_t park_stop;

/* The runtime's loop: epochs, then work, then the park. */
static void
park_worker_helper(uint64_t arg)
{
	const uint32_t slot = erx_executor_slot();

	(void)arg;
	while (atomic_load_explicit(&park_stop, memory_order_acquire) == 0) {
		const uint64_t group = group_epoch(), epoch = slot_epoch(slot);
		uint32_t consumed = atomic_load_explicit(&park_consumed, memory_order_acquire);

		if (consumed < atomic_load_explicit(&park_published, memory_order_acquire)) {
			if (atomic_compare_exchange_strong_explicit(&park_consumed, &consumed, consumed + 1,
			    memory_order_acq_rel, memory_order_acquire))
				(void)erx_umtx_wake(word_addr(&park_consumed), 1);
			continue;
		}
		(void)erx_park(group, epoch, ERX_WAIT_FOREVER);
	}
	function_api_bump_done();
	erx_thread_exit();
}

/* Two executors and a trigger per round: one lost wake stops the turn. */
static bool
case_park_ping(void)
{
	atomic_store(&function_api_done, 0);
	for (uint32_t index = 0; index < PARK_EXECUTORS; index++)
		if (function_api_spawn_executor(park_worker_helper, index) != ERX_OK)
			return (false);
	for (uint32_t round = 1; round <= PARK_ROUNDS; round++) {
		atomic_store_explicit(&park_published, round, memory_order_release);
		erx_group_trigger();
		if (!function_api_wait_for(&park_consumed, round))
			return (false);
	}
	atomic_store_explicit(&park_stop, 1, memory_order_release);
	for (uint32_t index = 0; index < PARK_EXECUTORS; index++)
		erx_group_trigger();
	return (function_api_wait_for(&function_api_done, PARK_EXECUTORS));
}

static _Atomic uint32_t park_race_stop;
static _Atomic uint32_t park_race_slot;
static _Atomic uint32_t park_race_stale;

/* Parks with deadlines as short as the wakes come, then one with no waker: a stale up would return it woken. */
static void
park_race_helper(uint64_t arg)
{
	const uint32_t slot = erx_executor_slot();

	(void)arg;
	atomic_store_explicit(&park_race_slot, slot + 1, memory_order_release);
	for (uint32_t round = 0; round < RACE_ROUNDS; round++)
		(void)erx_park(group_epoch(), slot_epoch(slot), erx_clock_ns() + (round % 8 + 1) * 10000);
	atomic_store_explicit(&park_race_stop, 1, memory_order_release);
	/* The waker sees the stop only after its last wake has passed. */
	settle(5 * NS_PER_MS);
	if (erx_park(group_epoch(), slot_epoch(slot), erx_clock_ns() + 5 * NS_PER_MS) != ERX_ETIMEDOUT)
		atomic_store_explicit(&park_race_stale, 1, memory_order_release);
	function_api_bump_done();
	erx_thread_exit();
}

static bool
case_park_timeout_races_wake(void)
{
	uint32_t slot;

	atomic_store(&function_api_done, 0);
	if (function_api_spawn_executor(park_race_helper, 0) != ERX_OK)
		return (false);
	while ((slot = atomic_load_explicit(&park_race_slot, memory_order_acquire)) == 0)
		settle(NS_PER_MS);
	while (atomic_load_explicit(&park_race_stop, memory_order_acquire) == 0)
		(void)erx_executor_wake(slot - 1);
	return (function_api_wait_for(&function_api_done, 1) && atomic_load(&park_race_stale) == 0);
}

static bool
case_many_threads(void)
{
	atomic_store(&function_api_done, 0);
	for (uint32_t index = 0; index < MANY_THREADS; index++)
		if (!spawn(idle_helper, index, index))
			return (false);
	return (function_api_wait_for(&function_api_done, MANY_THREADS));
}

/* A bad way to end is refused, and the machine goes on. */
static bool
case_machine_end_refused(void)
{
	return (erx_machine_end(0, 0) == ERX_EINVAL && erx_machine_end(0, ERX_END_RESET + 1) == ERX_EINVAL);
}

/* The table's last indices never start: no free one is ERX_ENOMEM. */
static bool
case_indices_run_out(void)
{
	erx_utcb_t *const utcb = erx_utcb_self();
	uint64_t thread;
	int status;
	uint32_t made = 0;

	for (size_t word = 0; word < sizeof(erx_thread_start_t) / sizeof(uint64_t); word++)
		erx_utcb_mr_store(utcb, word, 0);
	while ((status = erx_thread_create(0, 0, 0, ERX_THREAD_CLASS_WORKER, &thread)) == ERX_OK && made < 4096)
		made++;
	return (status == ERX_ENOMEM && made > 0);
}

#define ENTROPY_FILL	UINT64_C(0xaaaaaaaaaaaaaaaa)

/* Two reads differ, and a read fills what it says and no byte past it. */
static bool
case_entropy_read(void)
{
	erx_utcb_t *const utcb = erx_utcb_self();
	const uint32_t last = ERX_ENTROPY_BYTES_MAX / sizeof(uint64_t) - 1;
	uint64_t first[2];

	atomic_store(&utcb->mr[0], ENTROPY_FILL);
	if (erx_entropy_read(0) != ERX_OK || atomic_load(&utcb->mr[0]) != ENTROPY_FILL ||
	    erx_entropy_read(3) != ERX_OK || atomic_load(&utcb->mr[0]) >> 24 != ENTROPY_FILL >> 24)
		return (false);
	atomic_store(&utcb->mr[2], ENTROPY_FILL);
	if (erx_entropy_read(2 * sizeof(uint64_t)) != ERX_OK || atomic_load(&utcb->mr[2]) != ENTROPY_FILL)
		return (false);
	first[0] = atomic_load(&utcb->mr[0]);
	first[1] = atomic_load(&utcb->mr[1]);
	atomic_store(&utcb->mr[last], ENTROPY_FILL);
	if (erx_entropy_read(ERX_ENTROPY_BYTES_MAX) != ERX_OK || atomic_load(&utcb->mr[last]) == ENTROPY_FILL)
		return (false);
	return (atomic_load(&utcb->mr[0]) != first[0] || atomic_load(&utcb->mr[1]) != first[1]);
}

static bool
case_entropy_add(void)
{
	erx_utcb_t *const utcb = erx_utcb_self();

	for (uint32_t word = 0; word < 8; word++)
		atomic_store(&utcb->mr[word], word);
	return (erx_entropy_add(0, 0, 0) == ERX_OK && erx_entropy_add(0, 8 * sizeof(uint64_t) - 1, 0) == ERX_OK &&
	    erx_entropy_read(16) == ERX_OK);
}

static bool
case_entropy_refusals(void)
{
	return (erx_entropy_read(ERX_ENTROPY_BYTES_MAX + 1) == ERX_EINVAL &&
	    erx_entropy_add(0, ERX_ENTROPY_BYTES_MAX + 1, 0) == ERX_EINVAL &&
	    erx_entropy_add(0, 8, (uint32_t)ERX_ENTROPY_CREDIT << 1) == ERX_EINVAL &&
	    erx_entropy_add(0, 8, ERX_ENTROPY_CREDIT) == ERX_ENOTSUP);
}

/* What is wrong with a request before any device comes into it. */
static bool
case_mem_device_refusals(void)
{
	const uint64_t page = ERX_PAGE_SIZE;
	uint64_t mem, addr;

	return (erx_mem_create_physical(0, 0, page, 0, ERX_MEM_ATTR_DEVICE, &mem) == ERX_EINVAL &&
	    erx_mem_create_physical(0, 0, page + 1, page, ERX_MEM_ATTR_DEVICE, &mem) == ERX_EINVAL &&
	    erx_mem_create_physical(0, 0, page, page + 1, ERX_MEM_ATTR_DEVICE, &mem) == ERX_EINVAL &&
	    erx_mem_create_physical(0, 0, UINT64_MAX - page + 1, page, ERX_MEM_ATTR_DEVICE, &mem) == ERX_EINVAL &&
	    erx_mem_create_physical(0, 0, page, page, ERX_MEM_ATTR_DEVICE + 1, &mem) == ERX_EINVAL &&
	    erx_mem_create_contiguous(0, 0, 0, 0, &mem) == ERX_EINVAL &&
	    erx_mem_create_contiguous(0, 0, page + 1, 0, &mem) == ERX_EINVAL &&
	    erx_mem_create_contiguous(0, 0, ERX_MEM_CONTIGUOUS_MAX + page, 0, &mem) == ERX_EINVAL &&
	    erx_mem_dma_addr(UINT64_C(1) << 40, 0, &addr) == ERX_EINVAL);
}

static const function_api_case_t shared_cases[] = {
	{ "decommit_recommit_reads_zeros", case_decommit_recommit_reads_zeros },
	{ "released_pages_read_zeros", case_released_pages_read_zeros },
	{ "no_access_and_back_keeps_contents", case_no_access_and_back_keeps_contents },
	{ "read_only_raises_to_read_write", case_read_only_raises_to_read_write },
	{ "stack_through_no_access", case_stack_through_no_access },
	{ "refused_protect_changes_nothing", case_refused_protect_changes_nothing },
	{ "write_and_execute_refused", case_write_and_execute_refused },
	{ "refusals", case_refusals },
	{ "fixed_reserve_replaces", case_fixed_reserve_replaces },
	{ "every_protection_change", case_every_protection_change },
	{ "many_pages_between_write_and_execute", case_many_pages_between_write_and_execute },
	{ "whole_pool_commits", case_whole_pool_commits },
	{ "pool_count_steady", case_pool_count_steady },
	{ "tls_and_arg", case_tls_and_arg },
	{ "utcb_is_each_threads", case_utcb_is_each_threads },
	{ "double_start_refused", case_double_start_refused },
	{ "bad_handle_refused", case_bad_handle_refused },
	{ "unsupported_refused", case_unsupported_refused },
	{ "group_info_and_configure", case_group_info_and_configure },
	{ "umtx_word_differs", case_umtx_word_differs },
	{ "umtx_past_deadline", case_umtx_past_deadline },
	{ "umtx_timeout_not_early", case_umtx_timeout_not_early },
	{ "umtx_wake_counts", case_umtx_wake_counts },
	{ "umtx_ping_pong", case_umtx_ping_pong },
	{ "umtx_timeout_races_wake", case_umtx_timeout_races_wake },
	{ "memory_from_threads", case_memory_from_threads },
	{ "affinity_refused", case_affinity_refused },
	{ "join_loop", case_join_loop },
	{ "detached_loop", case_detached_loop },
	{ "park_refusals", case_park_refusals },
	{ "park_alone", case_park_alone },
	{ "park_trigger_in_window", case_park_trigger_in_window },
	{ "park_ping", case_park_ping },
	{ "park_timeout_races_wake", case_park_timeout_races_wake },
	{ "many_threads", case_many_threads },
	{ "machine_end_refused", case_machine_end_refused },
	{ "entropy_read", case_entropy_read },
	{ "entropy_add", case_entropy_add },
	{ "entropy_refusals", case_entropy_refusals },
	{ "mem_device_refusals", case_mem_device_refusals },
};

static void
report(const char *name, bool ok)
{
	function_api_say("erx: function-api: ");
	function_api_say(name);
	function_api_say(ok ? " ok\n" : " FAILED\n");
}

void
function_api_run(const function_api_case_t *extra, size_t nextra, const function_api_case_t *device, size_t ndevice)
{
	pool_at_start = erx_vm_free_pages();
	for (size_t index = 0; index < sizeof(shared_cases) / sizeof(shared_cases[0]); index++)
		report(shared_cases[index].name, shared_cases[index].run());
	for (size_t index = 0; index < nextra; index++)
		report(extra[index].name, extra[index].run());
	for (size_t index = 0; index < ndevice; index++)
		report(device[index].name, device[index].run());
	report("indices_run_out", case_indices_run_out());
	function_api_say("erx: function-api: done\n");
	(void)erx_machine_end(0, ERX_END_OFF);
	function_api_say("erx: function-api: machine end refused FAILED\n");
}
