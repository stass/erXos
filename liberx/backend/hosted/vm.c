/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

/*
 * The memory calls in a macOS process, the range table's effects over one mmapped
 * area (docs/design-stopgap.md, "The hosted backend"). A page's contents live at its
 * own address, so the pool is only a count. Host pages hold several of the ABI's
 * pages on Apple Silicon: each host page's protection is the union of its pages',
 * and contents are cleaned lazily, so a commit of whole host pages touches nothing.
 * A call's effects only record each page's rights, and the host pages it touched
 * change once it is whole, so a range moving between write and execute never meets
 * itself halfway. A reserve's search starts on a host page, so unrelated ranges share none.
 *
 * An uncommitted page that may hold its last holder's bytes is marked dirty when
 * given back. A take cleans a dirty page; a host page none of whose pages is
 * committed goes back to the host as a fresh mapping, which cleans all of them.
 * Everything here runs under vm_lock.
 *
 * With ERX_HOSTED_VM_RUNS set, the console gets a line each time a call changes the
 * count of the table's runs or of committed pages, which tells make
 * check-runtime-hosted how close a runtime comes to the limit it shares with the
 * native backend.
 */

#include <errno.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/random.h>
#include <unistd.h>

#include "erx/abi.h"
#include "erx/explicit_bzero.h"
#include "liberx/backend/api.h"
#include "liberx/backend/core/device_check.h"
#include "liberx/backend/core/entropy_read.h"
#include "liberx/backend/core/vm_table.h"
#include "liberx/backend/hosted/internal.h"

#define PAGE		((uint64_t)ERX_PAGE_SIZE)
#define VM_AREA_BYTES	(UINT64_C(64) * 1024 * 1024 * 1024)
#define VM_POOL_PAGES	(UINT64_C(8) * 1024 * 1024 * 1024 / PAGE)

/* One byte per page of the area: its rights, and two facts the table does not hold. */
#define PAGE_RIGHTS	UINT8_C(0x07)
#define PAGE_COMMITTED	UINT8_C(0x40)
#define PAGE_DIRTY	UINT8_C(0x80)

static void	vm_init(void);
static void	vm_map(uint32_t, uintptr_t, uint64_t, uint32_t);
static void	vm_unmap(uint32_t, uint64_t, uint32_t);
static uintptr_t vm_take(uint64_t);
static void	vm_give(uintptr_t, uint64_t);
static void	vm_unmapped(uint32_t);
static uint64_t	vm_free_count(void);
static uintptr_t vm_record_take(void);
static void	vm_record_give(uintptr_t);

static const erx_backend_vm_effects_t vm_effects = { .map = vm_map, .unmap = vm_unmap, .take = vm_take,
    .give = vm_give, .free_pages = vm_free_count, .unmapped = vm_unmapped };
static const erx_backend_grow_pages_t vm_records = { .take = vm_record_take, .give = vm_record_give };

static pthread_once_t vm_once = PTHREAD_ONCE_INIT;
static pthread_mutex_t vm_lock = PTHREAD_MUTEX_INITIALIZER;
static erx_backend_vm_table_t vm_table;
static uint64_t vm_free;
static uint64_t vm_area;
static uint64_t vm_host_page;
static uint8_t *vm_page_bytes;	/* one per ABI page of the area */
static uint8_t *vm_host_rights;	/* one per host page of the area: what the host holds now */
static uint64_t vm_touched_low;	/* the pages this call's effects changed, as a range */
static uint64_t vm_touched_high;
static bool vm_runs_reported;
static size_t vm_runs_last;
static size_t vm_runs_high;
static uint64_t vm_committed_last;

static void *
vm_map_host(uint64_t bytes, int prot)
{
	void *const memory = mmap(NULL, (size_t)bytes, prot, MAP_ANON | MAP_PRIVATE, -1, 0);

	if (memory == MAP_FAILED)
		erx_hosted_fatal("erx: hosted: the host refused the memory area\n");
	return (memory);
}

/* The range table's own pages come from the host, outside the pool's count. */
static uintptr_t
vm_record_take(void)
{
	void *page = NULL;

	return (posix_memalign(&page, (size_t)PAGE, (size_t)PAGE) == 0 ? (uintptr_t)page : 0);
}

static void
vm_record_give(uintptr_t page)
{
	free((void *)page);
}

static void
vm_init(void)
{
	const erx_backend_vm_layout_t layout = erx_backend_vm_layout(VM_POOL_PAGES);
	void *const index = vm_map_host(layout.index_pages * PAGE, PROT_READ | PROT_WRITE);

	vm_host_page = (uint64_t)getpagesize();
	vm_area = (uint64_t)(uintptr_t)vm_map_host(VM_AREA_BYTES, PROT_NONE);
	vm_page_bytes = vm_map_host(VM_AREA_BYTES / PAGE, PROT_READ | PROT_WRITE);
	vm_host_rights = vm_map_host(VM_AREA_BYTES / vm_host_page, PROT_READ | PROT_WRITE);
	erx_backend_vm_index_init(index, (size_t)layout.index_slots);
	erx_backend_vm_table_init(&vm_table, 0, index, (size_t)layout.index_slots, vm_area,
	    vm_area + VM_AREA_BYTES, &vm_records);
	vm_table.placement = vm_host_page;
	vm_free = VM_POOL_PAGES;
}

void
erx_hosted_vm_report_runs(void)
{
	vm_runs_reported = true;
}

static void
vm_runs_note(void)
{
	const uint64_t committed = VM_POOL_PAGES - vm_free;
	char line[128];

	if (!vm_runs_reported || (vm_table.nranges == vm_runs_last && committed == vm_committed_last))
		return;
	vm_runs_last = vm_table.nranges;
	vm_committed_last = committed;
	if (vm_runs_last > vm_runs_high)
		vm_runs_high = vm_runs_last;
	(void)snprintf(line, sizeof(line), "erx: hosted: range table: runs %zu high %zu of %u committed_pages %llu\n",
	    vm_runs_last, vm_runs_high, erx_backend_grow_table_limit(&vm_table.runs), (unsigned long long)committed);
	erx_hosted_note(line);
}

static uint64_t
vm_free_count(void)
{
	return (vm_free);
}

static uint64_t
host_index(uint64_t addr)
{
	return ((addr - vm_area) / vm_host_page);
}

static uint8_t *
page_byte(uint64_t addr)
{
	return (&vm_page_bytes[(addr - vm_area) / PAGE]);
}

static int
host_prot(uint8_t rights)
{
	return (((rights & ERX_PROT_R) != 0 ? PROT_READ : 0) | ((rights & (ERX_PROT_RW & ~ERX_PROT_R)) != 0 ? PROT_WRITE : 0) |
	    ((rights & (ERX_PROT_RX & ~ERX_PROT_R)) != 0 ? PROT_EXEC : 0));
}

/* Gives a host page the union of its pages' rights. Write and execute together cannot be: see the design. */
static void
host_refresh(uint64_t addr)
{
	const uint64_t host = addr & ~(vm_host_page - 1);
	uint8_t rights = 0;

	for (uint64_t page = host; page < host + vm_host_page; page += PAGE)
		rights |= *page_byte(page) & PAGE_RIGHTS;
	if (host_prot(rights) == (PROT_READ | PROT_WRITE | PROT_EXEC))
		erx_hosted_fatal("erx: hosted: a writable and an executable page share one host page\n");
	if (vm_host_rights[host_index(host)] == rights)
		return;
	if (mprotect((void *)(uintptr_t)host, (size_t)vm_host_page, host_prot(rights)) != 0)
		erx_hosted_fatal("erx: hosted: the host refused a protection\n");
	vm_host_rights[host_index(host)] = rights;
}

static void
page_touched(uint64_t addr)
{
	if (vm_touched_high == 0 || addr < vm_touched_low)
		vm_touched_low = addr;
	if (addr + PAGE > vm_touched_high)
		vm_touched_high = addr + PAGE;
}

static void
vm_map(uint32_t label, uintptr_t window, uint64_t addr, uint32_t prot)
{
	(void)label;
	(void)window;
	*page_byte(addr) |= (uint8_t)prot & PAGE_RIGHTS;
	page_touched(addr);
}

/* As on a real table a read right's unmap takes the mapping whole. */
static void
vm_unmap(uint32_t label, uint64_t addr, uint32_t rights)
{
	uint8_t *const byte = page_byte(addr);

	(void)label;
	if ((rights & ERX_PROT_R) != 0)
		*byte &= (uint8_t)~PAGE_RIGHTS;
	else
		*byte &= (uint8_t)~rights;
	page_touched(addr);
}

/* A dirty page's sibling keeps the host page mapped, so the bytes are cleaned under a brief write right. */
static void
page_clean(uint64_t addr)
{
	const uint64_t host = addr & ~(vm_host_page - 1);
	const uint8_t held = vm_host_rights[host_index(host)];
	const bool writable = (host_prot(held) & PROT_WRITE) != 0;

	if (!writable && mprotect((void *)(uintptr_t)host, (size_t)vm_host_page, PROT_READ | PROT_WRITE) != 0)
		erx_hosted_fatal("erx: hosted: the host refused a protection\n");
	memset((void *)(uintptr_t)addr, 0, (size_t)PAGE);
	if (!writable && mprotect((void *)(uintptr_t)host, (size_t)vm_host_page, host_prot(held)) != 0)
		erx_hosted_fatal("erx: hosted: the host refused a protection\n");
}

static uintptr_t
vm_take(uint64_t addr)
{
	uint8_t *const byte = page_byte(addr);

	vm_free--;
	if ((*byte & PAGE_DIRTY) != 0)
		page_clean(addr);
	*byte = PAGE_COMMITTED;
	return ((uintptr_t)addr);
}

/* The last committed page of a host page returns all of it, and with it every dirty mark. */
static void
vm_give(uintptr_t window, uint64_t addr)
{
	const uint64_t host = addr & ~(vm_host_page - 1);
	uint8_t *const byte = page_byte(addr);

	(void)window;
	vm_free++;
	*byte = PAGE_DIRTY;
	for (uint64_t page = host; page < host + vm_host_page; page += PAGE)
		if ((*page_byte(page) & PAGE_COMMITTED) != 0)
			return;
	if (mmap((void *)(uintptr_t)host, (size_t)vm_host_page, PROT_NONE, MAP_ANON | MAP_PRIVATE | MAP_FIXED, -1, 0) ==
	    MAP_FAILED)
		erx_hosted_fatal("erx: hosted: the host refused to take a page back\n");
	vm_host_rights[host_index(host)] = 0;
	for (uint64_t page = host; page < host + vm_host_page; page += PAGE)
		*page_byte(page) = 0;
}

/* Hosted maps no object, so its table holds no mapping record to drop. */
static void
vm_unmapped(uint32_t object)
{
	(void)object;
}

/* Hosted makes no spaces, so ERX_CAP_SELF is the one space a call can name. */
static int
vm_call(uint64_t space, erx_backend_vm_op_t op, uint64_t addr, uint64_t size, uint32_t flags, uint32_t prot, uint64_t *reserved)
{
	const erx_backend_vm_request_t request = { .op = op, .addr = addr, .size = size, .flags = flags, .prot = prot };
	int status;

	if (space != ERX_CAP_SELF)
		return (ERX_EINVAL);
	(void)pthread_once(&vm_once, vm_init);
	(void)pthread_mutex_lock(&vm_lock);
	status = erx_backend_vm_call(&vm_table, &vm_effects, &request, reserved);
	vm_runs_note();
	if (vm_touched_high != 0)
		for (uint64_t host = vm_touched_low & ~(vm_host_page - 1); host < vm_touched_high; host += vm_host_page)
			host_refresh(host);
	vm_touched_low = 0;
	vm_touched_high = 0;
	(void)pthread_mutex_unlock(&vm_lock);
	return (status);
}

int
erx_vm_reserve(uint64_t space, uint64_t addr, uint64_t size, uint32_t flags, uint64_t *reserved)
{
	return (vm_call(space, ERX_BACKEND_VM_RESERVE, addr, size, flags, 0, reserved));
}

int
erx_vm_commit(uint64_t space, uint64_t addr, uint64_t size)
{
	return (vm_call(space, ERX_BACKEND_VM_COMMIT, addr, size, 0, 0, NULL));
}

int
erx_vm_decommit(uint64_t space, uint64_t addr, uint64_t size)
{
	return (vm_call(space, ERX_BACKEND_VM_DECOMMIT, addr, size, 0, 0, NULL));
}

int
erx_vm_release(uint64_t space, uint64_t addr, uint64_t size)
{
	return (vm_call(space, ERX_BACKEND_VM_RELEASE, addr, size, 0, 0, NULL));
}

int
erx_space_protect(uint64_t space, uint64_t addr, uint64_t size, uint32_t prot)
{
	return (vm_call(space, ERX_BACKEND_VM_PROTECT, addr, size, 0, prot, NULL));
}

/* The hosted process is the system domain alone, which ends by exiting, so no space stops. */
int
erx_space_stop(uint64_t space, int64_t status)
{
	(void)space;
	(void)status;
	return (ERX_ENOTSUP);
}

uint64_t
erx_vm_free_pages(void)
{
	uint64_t count;

	(void)pthread_once(&vm_once, vm_init);
	(void)pthread_mutex_lock(&vm_lock);
	count = vm_free;
	(void)pthread_mutex_unlock(&vm_lock);
	return (count);
}

uint64_t
erx_hosted_vm_used_pages(void)
{
	return (VM_POOL_PAGES - erx_vm_free_pages());
}

uint64_t
erx_hosted_vm_pool_pages(void)
{
	return (VM_POOL_PAGES);
}

int
erx_vm_map(uint64_t space, uint64_t addr, uint64_t size, uint64_t mem, uint64_t offset, uint32_t prot)
{
	(void)space;
	(void)addr;
	(void)size;
	(void)mem;
	(void)offset;
	(void)prot;
	return (ERX_EINVAL);
}

/* No device exists here, so a device's address would be made up: docs/design-stopgap.md, "The hosted backend". */
int
erx_mem_create_physical(uint64_t budget, uint64_t resource, uint64_t base, uint64_t size, uint32_t attr, uint64_t *mem)
{
	const int status = erx_backend_physical_check(base, size, attr);

	(void)budget;
	(void)resource;
	(void)mem;
	return (status != ERX_OK ? status : ERX_ENOTSUP);
}

int
erx_mem_create_contiguous(uint64_t budget, uint64_t resource, uint64_t size, uint64_t limit, uint64_t *mem)
{
	const int status = erx_backend_contiguous_check(size);

	(void)budget;
	(void)resource;
	(void)limit;
	(void)mem;
	return (status != ERX_OK ? status : ERX_ENOTSUP);
}

int
erx_mem_create_contiguous_in(uint64_t budget, uint64_t size, const erx_mem_dma_range_t *range, uint64_t *mem)
{
	int status = erx_backend_contiguous_check(size);

	if (status == ERX_OK)
		status = erx_backend_dma_range_check(range->cpu, range->bus, range->last);
	(void)budget;
	(void)mem;
	return (status != ERX_OK ? status : ERX_ENOTSUP);
}

/* No call makes an object it answers for, so no handle names one. */
int
erx_mem_dma_addr(uint64_t mem, uint64_t offset, uint64_t *addr)
{
	(void)mem;
	(void)offset;
	(void)addr;
	return (ERX_EINVAL);
}

/*
 * Whether this read is one ERX_HOSTED_ENTROPY_FAIL fails. Its value N lets the first N reads of
 * the process through and fails every later one, so a test fails the reads after boot (N = 1,
 * the reference key's read) or every read (N = 0). A value that is not a decimal count fails
 * every read.
 */
static bool
entropy_read_fails(void)
{
	static _Atomic uint64_t reads;
	const char *word = getenv("ERX_HOSTED_ENTROPY_FAIL");
	char *end = NULL;
	unsigned long long through;

	if (word == NULL)
		return (false);
	errno = 0;
	through = strtoull(word, &end, 10);
	if (*word < '0' || *word > '9' || *end != '\0' || errno != 0)
		through = 0;
	return (atomic_fetch_add(&reads, 1) >= through);
}

/*
 * The host's getentropy. A read ERX_HOSTED_ENTROPY_FAIL fails is ERX_ENOTSUP, the failure the
 * native backend gives when it cannot reach its generator service, so a test sees it.
 */
int
erx_entropy_read(uint32_t len)
{
	uint64_t words[ERX_ENTROPY_BYTES_MAX / sizeof(uint64_t)] = { 0 };
	const int checked = erx_backend_entropy_read_check(len);

	if (checked != ERX_OK)
		return (checked);
	if (entropy_read_fails())
		return (ERX_ENOTSUP);
	if (len != 0 && getentropy(words, len) != 0) {
		/* getentropy may have filled part of words before it failed. */
		erx_explicit_bzero(words, sizeof(words));
		return (ERX_ENOTSUP);
	}
	for (uint32_t done = 0; done < len; done += sizeof(uint64_t))
		erx_backend_mr_put_bytes(erx_utcb_self(), done, words[done / sizeof(uint64_t)], len);
	erx_explicit_bzero(words, sizeof(words));
	return (ERX_OK);
}

/* The host's generator takes nothing from a program, so the bytes go nowhere. */
int
erx_entropy_add(uint64_t res, uint32_t len, uint32_t flags)
{
	(void)res;
	return (erx_backend_entropy_add_check(len, flags));
}
