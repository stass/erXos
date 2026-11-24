/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

/*
 * The caller's side of the service's calls: each stub fills its request's layout
 * from abi/erx_abi.txt and sends it through the task's gate. No address crosses
 * except as a value.
 */

#include <stdatomic.h>
#include <stddef.h>
#include <stdint.h>

#include <l4/sys/ipc.h>
#include <l4/sys/irq.h>
#include <l4/sys/utcb.h>

#include "erx/abi.h"
#include "erx/explicit_bzero.h"
#include "liberx/backend/api.h"
#include "liberx/backend/core/device_check.h"
#include "liberx/backend/core/entropy_read.h"
#include "liberx/backend/core/gate.h"
#include "liberx/backend/core/handles.h"
#include "liberx/backend/fiasco/root_layout.h"
#include "liberx/backend/fiasco/service.h"
#include "liberx/backend/fiasco/thread.h"
#include "liberx/backend/fiasco/vm.h"
#include "liberx/generated/calls.h"

#ifdef ERX_FIASCO_TEST_HOOKS
_Static_assert(ERX_FIASCO_TEST_EMPTY_SLOT_ERROR == L4_IPC_ENOT_EXISTENT, "Fiasco's error for an empty slot");

/*
 * Slot 0 lies before Fiasco's base capabilities, the first of which is slot 1
 * (L4_BASE_TASK_CAP), and before every slot root_layout.h plans, so it is empty in every task.
 */
uint64_t
erx_fiasco_test_empty_slot_call(void)
{
	l4_utcb_t *const utcb = l4_utcb();

	return (l4_ipc_error(l4_ipc_call(0, utcb, l4_msgtag(0, 0, 0, 0), L4_IPC_NEVER), utcb));
}
#endif

static int stub_range(uint32_t, uint64_t, uint64_t, uint64_t);
static int stub_flagged(uint32_t, uint64_t, uint64_t, uint64_t, uint64_t, uint64_t *);
static int stub_copy(uint32_t, uint64_t, uint64_t, uint64_t, uint64_t, uint64_t);

int
erx_fiasco_service_call(uint32_t number, const void *request, size_t bytes, erx_fiasco_reply_t *reply)
{
	l4_utcb_t *const utcb = l4_utcb();
	l4_msg_regs_t *const mr = l4_utcb_mr_u(utcb);
	const uint64_t *const words = request;
	const size_t count = bytes / sizeof(uint64_t);
	l4_msgtag_t tag;

	for (size_t index = 0; index < count; index++)
		mr->mr[index] = words[index];
	tag = l4_ipc_call(erx_fiasco_service_gate(), utcb,
	    l4_msgtag((long)number, (unsigned)count, 0, 0), L4_IPC_NEVER);
	if (l4_ipc_error(tag, utcb) != 0)
		return (ERX_EINVAL);
	reply->status = (int64_t)mr->mr[0];
	reply->first = mr->mr[1];
	reply->second = mr->mr[2];
	reply->third = mr->mr[3];
	reply->fourth = mr->mr[4];
	return ((int)reply->status);
}

static int
stub_range(uint32_t number, uint64_t space, uint64_t addr, uint64_t size)
{
	const erx_fiasco_vm_range_request_t request = { .caller = erx_fiasco_thread_self()->index, .space = space,
	    .addr = addr, .size = size };
	erx_fiasco_reply_t reply;

	return (erx_fiasco_service_call(number, &request, sizeof(request), &reply));
}

static int
stub_flagged(uint32_t number, uint64_t space, uint64_t addr, uint64_t size, uint64_t flags, uint64_t *first)
{
	const erx_fiasco_vm_flagged_request_t request = { .caller = erx_fiasco_thread_self()->index, .space = space,
	    .addr = addr, .size = size, .flags = flags };
	erx_fiasco_reply_t reply;
	const int status = erx_fiasco_service_call(number, &request, sizeof(request), &reply);

	if (status == ERX_OK && first != NULL)
		*first = reply.first;
	return (status);
}

erx_status_t
erx_debug_log(erx_utcb_length_t len)
{
	const erx_fiasco_debug_log_request_t request = { .caller = erx_fiasco_thread_self()->index, .len = len.raw };
	erx_fiasco_reply_t reply;

	return (erx_fiasco_service_call(ERX_CALL_DEBUG_LOG, &request, sizeof(request), &reply));
}

int
erx_log_read(uint64_t res, uint64_t cursor, void *window, uint64_t size, erx_log_read_result_t *result)
{
	const erx_fiasco_log_read_request_t request = { .caller = erx_fiasco_thread_self()->index,
	    .cursor = cursor, .window = (uint64_t)(uintptr_t)window, .size = size };
	erx_fiasco_reply_t reply;
	const int status = erx_fiasco_service_call(ERX_FIASCO_CALL_LOG_READ, &request, sizeof(request), &reply);

	(void)res;
	if (status == ERX_OK)
		*result = (erx_log_read_result_t){ .next_cursor = reply.first, .lost = reply.second,
		    .written = reply.third };
	return (status);
}

int
erx_log_take(uint64_t res, void *window, uint64_t size, erx_log_read_result_t *result)
{
	const erx_fiasco_log_take_request_t request = { .caller = erx_fiasco_thread_self()->index,
	    .window = (uint64_t)(uintptr_t)window, .size = size };
	erx_fiasco_reply_t reply;
	const int status = erx_fiasco_service_call(ERX_FIASCO_CALL_LOG_TAKE, &request, sizeof(request), &reply);

	(void)res;
	if (status == ERX_OK)
		*result = (erx_log_read_result_t){ .next_cursor = reply.first, .lost = reply.second,
		    .written = reply.third };
	return (status);
}

/* length is at most ERX_UTCB_BYTES_MAX, so every word index is in range and no store fails. */
void
erx_fiasco_utcb_store_bytes(const void *bytes, size_t length)
{
	const uint8_t *const text = bytes;
	erx_utcb_t *const utcb = erx_utcb_self();

	for (size_t done = 0; done < length; done += sizeof(uint64_t)) {
		uint64_t word = 0;

		__builtin_memcpy(&word, text + done, length - done < sizeof(word) ? length - done : sizeof(word));
		(void)erx_utcb_mr_store(utcb, done / sizeof(word), word);
	}
}

void
erx_fiasco_task_write(const void *bytes, size_t length)
{
	const uint8_t *next = bytes;
	erx_fiasco_task_write_request_t request = { .caller = erx_fiasco_thread_self()->index };
	erx_fiasco_reply_t reply;

	while (length > 0) {
		const size_t part = length < ERX_UTCB_BYTES_MAX ? length : ERX_UTCB_BYTES_MAX;

		erx_fiasco_utcb_store_bytes(next, part);
		request.len = part;
		(void)erx_fiasco_service_call(ERX_FIASCO_CALL_TASK_WRITE, &request, sizeof(request), &reply);
		next += part;
		length -= part;
	}
}

int
erx_vm_reserve(uint64_t space, uint64_t addr, uint64_t size, uint32_t flags, uint64_t *reserved)
{
	return (stub_flagged(ERX_FIASCO_CALL_VM_RESERVE, space, addr, size, flags, reserved));
}

int
erx_vm_commit(uint64_t space, uint64_t addr, uint64_t size)
{
	return (stub_range(ERX_FIASCO_CALL_VM_COMMIT, space, addr, size));
}

int
erx_vm_decommit(uint64_t space, uint64_t addr, uint64_t size)
{
	return (stub_range(ERX_FIASCO_CALL_VM_DECOMMIT, space, addr, size));
}

int
erx_vm_release(uint64_t space, uint64_t addr, uint64_t size)
{
	return (stub_range(ERX_FIASCO_CALL_VM_RELEASE, space, addr, size));
}

int
erx_space_protect(uint64_t space, uint64_t addr, uint64_t size, uint32_t prot)
{
	return (stub_flagged(ERX_FIASCO_CALL_SPACE_PROTECT, space, addr, size, prot, NULL));
}

int
erx_mem_create(uint64_t budget, uint64_t size, uint32_t flags, uint64_t *mem)
{
	const erx_fiasco_mem_create_request_t request = { .caller = erx_fiasco_thread_self()->index, .budget = budget,
	    .size = size, .flags = flags };
	erx_fiasco_reply_t reply;
	const int status = erx_fiasco_service_call(ERX_FIASCO_CALL_MEM_CREATE, &request, sizeof(request), &reply);

	if (status == ERX_OK)
		*mem = reply.first;
	return (status);
}

int
erx_vm_map(uint64_t space, uint64_t addr, uint64_t size, uint64_t mem, uint64_t offset, uint32_t prot)
{
	const erx_fiasco_vm_map_request_t request = { .caller = erx_fiasco_thread_self()->index, .space = space, .addr = addr,
	    .size = size, .mem = mem, .offset = offset, .prot = prot };
	erx_fiasco_reply_t reply;

	return (erx_fiasco_service_call(ERX_FIASCO_CALL_VM_MAP, &request, sizeof(request), &reply));
}

int
erx_mem_create_physical(uint64_t budget, uint64_t resource, uint64_t base, uint64_t size, uint32_t attr, uint64_t *mem)
{
	const erx_fiasco_mem_physical_request_t request = { .caller = erx_fiasco_thread_self()->index, .budget = budget,
	    .base = base, .size = size, .attr = attr };
	erx_fiasco_reply_t reply;
	const int status = erx_fiasco_service_call(ERX_FIASCO_CALL_MEM_CREATE_PHYSICAL, &request, sizeof(request), &reply);

	(void)resource;
	if (status == ERX_OK)
		*mem = reply.first;
	return (status);
}

int
erx_mem_create_contiguous_in(uint64_t budget, uint64_t size, const erx_mem_dma_range_t *range, uint64_t *mem)
{
	const erx_fiasco_mem_contiguous_request_t request = { .caller = erx_fiasco_thread_self()->index, .budget = budget,
	    .size = size, .cpu = range->cpu, .bus = range->bus, .last = range->last };
	erx_fiasco_reply_t reply;
	const int status = erx_fiasco_service_call(ERX_FIASCO_CALL_MEM_CREATE_CONTIGUOUS, &request, sizeof(request), &reply);

	if (status == ERX_OK)
		*mem = reply.first;
	return (status);
}

/* Device address limit with no translation: CPU addresses 0 through limit - 1, all of them for 0. */
int
erx_mem_create_contiguous(uint64_t budget, uint64_t resource, uint64_t size, uint64_t limit, uint64_t *mem)
{
	const erx_mem_dma_range_t below = { .cpu = 0, .bus = 0, .last = limit == 0 ? UINT64_MAX : limit - 1 };

	(void)resource;
	return (erx_mem_create_contiguous_in(budget, size, &below, mem));
}

int
erx_mem_dma_addr(uint64_t mem, uint64_t offset, uint64_t *addr)
{
	const erx_fiasco_mem_dma_request_t request = { .caller = erx_fiasco_thread_self()->index, .mem = mem,
	    .offset = offset };
	erx_fiasco_reply_t reply;
	const int status = erx_fiasco_service_call(ERX_FIASCO_CALL_MEM_DMA_ADDR, &request, sizeof(request), &reply);

	if (status == ERX_OK)
		*addr = reply.first;
	return (status);
}

/*
 * A reply holds two words, so a read asks for them until it has its bytes. The reply on the
 * stack is erased once its words are in mr, and a failed read zeroes mr's first len bytes,
 * so a failure leaves no entropy behind in mr. The generator service's copies, in
 * its own and this thread's Fiasco UTCB, are the Fiasco backend's (TODO.md, security residuals).
 */
int
erx_entropy_read(uint32_t len)
{
	const erx_fiasco_entropy_read_request_t request = { .caller = erx_fiasco_thread_self()->index };
	const int checked = erx_backend_entropy_read_check(len);
	erx_utcb_t *const utcb = erx_utcb_self();
	erx_fiasco_reply_t reply;
	int status;

	if (checked != ERX_OK)
		return (checked);
	status = ERX_OK;
	for (uint32_t done = 0; done < len && status == ERX_OK; done += 2 * sizeof(uint64_t)) {
		status = erx_fiasco_service_call(ERX_FIASCO_CALL_ENTROPY_READ, &request, sizeof(request), &reply);
		if (status == ERX_OK) {
			erx_backend_mr_put_bytes(utcb, done, reply.first, len);
			erx_backend_mr_put_bytes(utcb, done + sizeof(uint64_t), reply.second, len);
		}
		erx_explicit_bzero(&reply, sizeof(reply));
	}
	if (status != ERX_OK) {
		for (uint32_t at = 0; at < len; at += sizeof(uint64_t))
			erx_backend_mr_put_bytes(utcb, at, 0, len);
	}
	return (status);
}

/* A request holds four words of bytes, so a long add takes several. */
int
erx_entropy_add(uint64_t res, uint32_t len, uint32_t flags)
{
	const uint32_t chunk = 4 * sizeof(uint64_t);
	const int checked = erx_backend_entropy_add_check(len, flags);
	const erx_utcb_t *const utcb = erx_utcb_self();
	erx_fiasco_reply_t reply;

	(void)res;
	if (checked != ERX_OK)
		return (checked);
	for (uint32_t done = 0; done < len; done += chunk) {
		const uint32_t word = done / sizeof(uint64_t);
		const erx_fiasco_entropy_add_request_t request = { .caller = erx_fiasco_thread_self()->index,
		    .len = len - done < chunk ? len - done : chunk,
		    .word0 = atomic_load(&utcb->mr[word]), .word1 = atomic_load(&utcb->mr[word + 1]),
		    .word2 = atomic_load(&utcb->mr[word + 2]), .word3 = atomic_load(&utcb->mr[word + 3]) };
		const int status = erx_fiasco_service_call(ERX_FIASCO_CALL_ENTROPY_ADD, &request, sizeof(request), &reply);

		if (status != ERX_OK)
			return (status);
	}
	return (ERX_OK);
}

int
erx_space_create(uint64_t budget, uint64_t parent, uint64_t fault, uint64_t label, uint32_t flags, uint32_t cap_limit,
    uint64_t *space)
{
	const erx_fiasco_space_create_request_t request = { .caller = erx_fiasco_thread_self()->index, .budget = budget,
	    .parent = parent, .fault = fault, .label = label, .flags = flags, .cap_limit = cap_limit };
	erx_fiasco_reply_t reply;
	const int status = erx_fiasco_service_call(ERX_FIASCO_CALL_SPACE_CREATE, &request, sizeof(request), &reply);

	if (status == ERX_OK)
		*space = reply.first;
	return (status);
}

int
erx_space_create_domain(uint64_t budget, uint64_t parent, uint64_t fault, uint64_t label, uint32_t flags,
    uint32_t cap_limit, const erx_space_domain_t *domain, uint64_t *space)
{
	const erx_fiasco_domain_space_create_request_t request = { .space = { .caller = erx_fiasco_thread_self()->index,
	    .budget = budget, .parent = parent, .fault = fault, .label = label, .flags = flags, .cap_limit = cap_limit },
	    .band = domain->band, .space_band = domain->space_band, .cpuset = domain->cpuset,
	    .slice_us = domain->slice_us };
	erx_fiasco_reply_t reply;
	const int status = erx_fiasco_service_call(ERX_FIASCO_CALL_DOMAIN_SPACE_CREATE, &request, sizeof(request), &reply);

	if (status == ERX_OK)
		*space = reply.first;
	return (status);
}

uint32_t
erx_space_cap_limit_max(void)
{
	return (ERX_FIASCO_CAP_LIMIT_MAX);
}

int
erx_image_map(uint64_t space, uint64_t image, uint64_t entry, uint64_t *start)
{
	const erx_fiasco_image_map_request_t request = { .caller = erx_fiasco_thread_self()->index, .space = space,
	    .image = image, .entry = entry };
	erx_fiasco_reply_t reply;
	int status = erx_fiasco_image_check(image, entry);

	if (status == ERX_OK)
		status = erx_fiasco_service_call(ERX_FIASCO_CALL_IMAGE_MAP, &request, sizeof(request), &reply);
	if (status == ERX_OK)
		*start = reply.first;
	return (status);
}

int
erx_image_slice(uint64_t budget, uint64_t image, uint64_t first, uint64_t count, uint64_t *slice)
{
	const erx_fiasco_image_slice_request_t request = { .caller = erx_fiasco_thread_self()->index, .budget = budget,
	    .image = image, .first = first, .count = count };
	erx_fiasco_reply_t reply;
	const int status = erx_fiasco_service_call(ERX_FIASCO_CALL_IMAGE_SLICE, &request, sizeof(request), &reply);

	if (status == ERX_OK)
		*slice = reply.first;
	return (status);
}

/*
 * Every request checks the whole range, so a range refusal comes before any byte moves;
 * an object gone between two requests is ERX_ESTALE with the earlier parts copied.
 */
int
erx_mem_copy(uint64_t dst, uint64_t dst_offset, uint64_t src, uint64_t src_offset, uint64_t len)
{
	return (stub_copy(ERX_FIASCO_CALL_MEM_COPY, dst, dst_offset, src, src_offset, len));
}

/* erx_mem_supply is a copy into a paged object, under the same loop. */
int
erx_mem_supply(uint64_t mem, uint64_t offset, uint64_t src, uint64_t src_offset, uint64_t len)
{
	return (stub_copy(ERX_FIASCO_CALL_MEM_SUPPLY, mem, offset, src, src_offset, len));
}

static int
stub_copy(uint32_t call, uint64_t dst, uint64_t dst_offset, uint64_t src, uint64_t src_offset, uint64_t len)
{
	erx_fiasco_mem_copy_request_t request = { .caller = erx_fiasco_thread_self()->index, .dst = dst,
	    .dst_offset = dst_offset, .src = src, .src_offset = src_offset, .len = len, .done = 0 };
	erx_fiasco_reply_t reply;

	do {
		const int status = erx_fiasco_service_call(call, &request, sizeof(request), &reply);

		if (status != ERX_OK)
			return (status);
		if (reply.first <= request.done && reply.first < len)
			return (ERX_EINVAL);
		request.done = reply.first;
	} while (request.done < len);
	return (ERX_OK);
}

/*
 * The path comes in pieces of at most ERX_UTCB_BYTES_MAX bytes, one request each; the
 * reply's words are the size, the offset, the path's length and the entry's kind, which
 * is a file, an image or an empty directory. Without entry, the one request makes the
 * check alone.
 */
int
erx_fiasco_release_entry(uint64_t release, uint64_t index, bool check, erx_release_entry_t *entry)
{
	erx_utcb_t *const utcb = erx_utcb_self();
	erx_fiasco_release_entry_request_t request = { .caller = erx_fiasco_thread_self()->index, .release = release,
	    .index = index, .piece = 0, .check = check ? 1 : 0 };
	erx_fiasco_reply_t reply;

	uint64_t path_length;

	if (entry == NULL)
		return (erx_fiasco_service_call(ERX_FIASCO_CALL_RELEASE_ENTRY, &request, sizeof(request), &reply));
	do {
		const int status = erx_fiasco_service_call(ERX_FIASCO_CALL_RELEASE_ENTRY, &request, sizeof(request), &reply);

		if (status != ERX_OK)
			return (status);
		path_length = reply.third;
		if (path_length > sizeof(entry->path) || path_length < request.piece ||
		    (reply.fourth != ERX_ENTRY_FILE && reply.fourth != ERX_ENTRY_IMAGE &&
		    reply.fourth != ERX_ENTRY_DIRECTORY))
			return (ERX_ERANGE);
		const size_t part = path_length - request.piece < ERX_UTCB_BYTES_MAX ? (size_t)(path_length - request.piece) :
		    ERX_UTCB_BYTES_MAX;

		for (size_t done = 0; done < part; done += sizeof(uint64_t)) {
			uint64_t word = 0;

			(void)erx_utcb_mr_load(utcb, done / sizeof(word), &word);
			__builtin_memcpy(entry->path + request.piece + done, &word,
			    part - done < sizeof(word) ? part - done : sizeof(word));
		}
		request.piece += part;
		request.check = 0;
	} while (request.piece < path_length);
	entry->size = reply.first;
	entry->offset = reply.second;
	entry->kind = (uint8_t)reply.fourth;
	entry->path_length = (size_t)path_length;
	return (ERX_OK);
}

int
erx_mem_create_paged(uint64_t budget, uint64_t size, uint32_t flags, uint64_t *mem)
{
	const erx_fiasco_mem_create_request_t request = { .caller = erx_fiasco_thread_self()->index, .budget = budget,
	    .size = size, .flags = flags };
	erx_fiasco_reply_t reply;
	const int status = erx_fiasco_service_call(ERX_FIASCO_CALL_MEM_CREATE_PAGED, &request, sizeof(request), &reply);

	if (status == ERX_OK)
		*mem = reply.first;
	return (status);
}

int
erx_mem_seal(uint64_t mem)
{
	const erx_fiasco_cap_request_t request = { .caller = erx_fiasco_thread_self()->index, .cap = mem };
	erx_fiasco_reply_t reply;

	return (erx_fiasco_service_call(ERX_FIASCO_CALL_MEM_SEAL, &request, sizeof(request), &reply));
}

/*
 * A child is a private copy here (docs/design-fiasco.md, "The call table"): the
 * service makes it, its parent and range checked, and erx_mem_copy fills it 64 pages a
 * request; a failed copy closes it, which leaves nothing of it.
 */
int
erx_mem_child(uint64_t parent, uint64_t budget, uint64_t offset, uint64_t size, uint64_t *child)
{
	const erx_fiasco_mem_child_request_t request = { .caller = erx_fiasco_thread_self()->index, .parent = parent,
	    .budget = budget, .offset = offset, .size = size };
	erx_fiasco_reply_t reply;
	int status = erx_fiasco_service_call(ERX_FIASCO_CALL_MEM_CHILD, &request, sizeof(request), &reply);

	if (status != ERX_OK)
		return (status);
	status = erx_mem_copy(reply.first, 0, parent, offset, size);
	if (status != ERX_OK) {
		(void)erx_cap_close((erx_cap_t){ .raw = reply.first });
		return (status);
	}
	*child = reply.first;
	return (ERX_OK);
}

int
erx_cap_dup(uint64_t cap, uint64_t *copy)
{
	const erx_fiasco_cap_request_t request = { .caller = erx_fiasco_thread_self()->index, .cap = cap };
	erx_fiasco_reply_t reply;
	const int status = erx_fiasco_service_call(ERX_FIASCO_CALL_CAP_DUP, &request, sizeof(request), &reply);

	if (status == ERX_OK)
		*copy = reply.first;
	return (status);
}

int
erx_cap_pass(uint64_t from, uint64_t to, uint32_t n)
{
	const erx_fiasco_cap_pass_request_t request = { .caller = erx_fiasco_thread_self()->index, .from = from, .to = to,
	    .count = n };
	erx_fiasco_reply_t reply;

	return (erx_fiasco_service_call(ERX_FIASCO_CALL_CAP_PASS, &request, sizeof(request), &reply));
}

int
erx_cap_close(erx_cap_t cap)
{
	const erx_fiasco_cap_request_t request = { .caller = erx_fiasco_thread_self()->index, .cap = cap.raw };
	erx_fiasco_reply_t reply;

	return (erx_fiasco_service_call(ERX_FIASCO_CALL_CAP_CLOSE, &request, sizeof(request), &reply));
}

int
erx_object_destroy(uint64_t object)
{
	const erx_fiasco_cap_request_t request = { .caller = erx_fiasco_thread_self()->index, .cap = object };
	erx_fiasco_reply_t reply;

	return (erx_fiasco_service_call(ERX_FIASCO_CALL_OBJECT_DESTROY, &request, sizeof(request), &reply));
}

int
erx_budget_create(uint64_t parent, uint32_t kind, uint64_t guarantee, uint64_t cap, uint64_t *budget)
{
	const erx_fiasco_budget_create_request_t request = { .caller = erx_fiasco_thread_self()->index, .parent = parent,
	    .kind = kind, .guarantee = guarantee, .cap = cap };
	erx_fiasco_reply_t reply;
	const int status = erx_fiasco_service_call(ERX_FIASCO_CALL_BUDGET_CREATE, &request, sizeof(request), &reply);

	if (status == ERX_OK)
		*budget = reply.first;
	return (status);
}

int
erx_budget_resize(uint64_t budget, uint64_t guarantee, uint64_t cap)
{
	const erx_fiasco_budget_resize_request_t request = { .caller = erx_fiasco_thread_self()->index, .budget = budget,
	    .guarantee = guarantee, .cap = cap };
	erx_fiasco_reply_t reply;

	return (erx_fiasco_service_call(ERX_FIASCO_CALL_BUDGET_RESIZE, &request, sizeof(request), &reply));
}

/* No notice is ever sent: nothing counts a budget's spending (docs/design-fiasco.md, "Reporting a budget"). */
int
erx_budget_watch(uint64_t budget, uint64_t irq, uint64_t threshold)
{
	(void)budget;
	(void)irq;
	(void)threshold;
	return (ERX_ENOTSUP);
}

int
erx_irq_create(uint64_t budget, uint64_t resource, uint32_t kind, uint64_t selector, uint64_t *irq,
    erx_msi_message_t *message)
{
	const erx_fiasco_irq_create_request_t request = { .caller = erx_fiasco_thread_self()->index,
	    .kind = kind, .selector = selector, .budget = budget };
	erx_fiasco_reply_t reply;
	int status;

	(void)resource;
	status = erx_fiasco_service_call(ERX_FIASCO_CALL_IRQ_CREATE, &request, sizeof(request), &reply);
	if (status != ERX_OK)
		return (status);
	*irq = reply.first;
	/* The service writes the data word from a 32-bit interrupt id (irq.c). */
	if (message != NULL)
		*message = (erx_msi_message_t){ .address = reply.second, .data = (uint32_t)reply.third };
	return (ERX_OK);
}

/*
 * ERX_CAP_NULL unbinds. The service keeps every bind, writes each label and checks the
 * group, so a task other than the root binds only within its own home group (irq.c).
 */
int
erx_irq_bind(uint64_t irq, uint64_t group, uint64_t label)
{
	erx_fiasco_reply_t reply;

	if (group == ERX_CAP_NULL) {
		const erx_fiasco_irq_request_t request = { .caller = erx_fiasco_thread_self()->index, .irq = irq };

		return (erx_fiasco_service_call(ERX_FIASCO_CALL_IRQ_UNBIND, &request, sizeof(request), &reply));
	}

	const erx_fiasco_irq_bind_request_t request = { .caller = erx_fiasco_thread_self()->index,
	    .irq = irq, .group = group, .label = label };

	return (erx_fiasco_service_call(ERX_FIASCO_CALL_IRQ_BIND, &request, sizeof(request), &reply));
}

/*
 * A trigger and an ack are the holder's own, on the capability the root placed at the IRQ
 * slot the handle's number fixes, and make no request (docs/design-fiasco.md, "Handles").
 * Number 0 names no entry, and an empty slot is a closed, destroyed or never-placed entry's,
 * which Fiasco refuses: both are ERX_ESTALE. The generation is not checked here, so a value
 * whose entry was closed and taken again reaches the new entry's object (FD1).
 */
static l4_cap_idx_t
irq_slot(uint64_t irq)
{
	const uint32_t number = ERX_BACKEND_HANDLE_NUMBER(irq);

	return (number != 0 ? (l4_cap_idx_t)erx_fiasco_irq_slot_cap(number - 1) : L4_INVALID_CAP);
}

int
erx_irq_trigger(uint64_t irq)
{
	const l4_cap_idx_t slot = irq_slot(irq);

	return (l4_is_valid_cap(slot) && !l4_msgtag_has_error(l4_irq_trigger(slot)) ? ERX_OK : ERX_ESTALE);
}

int
erx_irq_ack(uint64_t irq)
{
	const l4_cap_idx_t slot = irq_slot(irq);

	return (l4_is_valid_cap(slot) && !l4_msgtag_has_error(l4_irq_unmask(slot)) ? ERX_OK : ERX_ESTALE);
}

int
erx_gate_create(uint64_t budget, uint64_t *gate)
{
	const erx_fiasco_gate_create_request_t request = { .caller = erx_fiasco_thread_self()->index, .budget = budget };
	erx_fiasco_reply_t reply;
	const int status = erx_fiasco_service_call(ERX_FIASCO_CALL_GATE_CREATE, &request, sizeof(request), &reply);

	if (status == ERX_OK)
		*gate = reply.first;
	return (status);
}

int
erx_gate_bind(uint64_t gate, uint64_t thread, uint64_t label)
{
	const erx_fiasco_gate_bind_request_t request = { .caller = erx_fiasco_thread_self()->index, .gate = gate,
	    .thread = thread, .label = label };
	erx_fiasco_reply_t reply;

	return (erx_fiasco_service_call(ERX_FIASCO_CALL_GATE_BIND, &request, sizeof(request), &reply));
}

/* erx_ipc_wait's effects: its two requests and the calling thread's semaphore. */
static bool
stub_gate_take(void *context, int *status)
{
	const erx_fiasco_gate_wait_request_t request = { .caller = erx_fiasco_thread_self()->index };
	erx_fiasco_reply_t reply;

	*status = erx_fiasco_service_call(ERX_FIASCO_CALL_GATE_WAIT, &request, sizeof(request), &reply);
	if (*status != ERX_OK || reply.first == 0)
		return (false);
	*(uint64_t *)context = reply.second;
	return (true);
}

static bool
stub_gate_down(void *context, uint64_t deadline)
{
	(void)context;
	return (erx_fiasco_semaphore_down(erx_fiasco_thread_self()->semaphore, deadline));
}

static bool
stub_gate_cancel(void *context)
{
	const erx_fiasco_gate_wait_request_t request = { .caller = erx_fiasco_thread_self()->index };
	erx_fiasco_reply_t reply;

	(void)context;
	/* A refused cancel cannot happen for a listed caller; reading it as taken off owes an up that may never come. */
	return (erx_fiasco_service_call(ERX_FIASCO_CALL_GATE_CANCEL, &request, sizeof(request), &reply) != ERX_OK ||
	    reply.first != 0);
}

static void
stub_gate_absorb(void *context)
{
	(void)context;
	(void)erx_fiasco_semaphore_down(erx_fiasco_thread_self()->semaphore, ERX_WAIT_FOREVER);
}

static const erx_backend_gate_wait_effects_t stub_gate_effects = { .take = stub_gate_take, .down = stub_gate_down,
    .cancel = stub_gate_cancel, .absorb = stub_gate_absorb };

int
erx_ipc_wait(uint64_t wait_by, erx_msgtag_t *tag, uint64_t *label)
{
	const int status = erx_backend_gate_wait(&stub_gate_effects, label, wait_by);

	/* A gate carries fault and exit records alone, each a message of an erx_fault_t's words. */
	tag->raw = 0;
	if (status == ERX_OK)
		(void)erx_msgtag_raw_words_set(&tag->raw, sizeof(erx_fault_t) / sizeof(uint64_t));
	return (status);
}

int
erx_space_stop(uint64_t space, int64_t status)
{
	const erx_fiasco_space_stop_request_t request = { .caller = erx_fiasco_thread_self()->index, .space = space,
	    .status = status };
	erx_fiasco_reply_t reply;

	return (erx_fiasco_service_call(ERX_FIASCO_CALL_SPACE_STOP, &request, sizeof(request), &reply));
}

int
erx_machine_end(uint64_t res, uint32_t how)
{
	const erx_fiasco_machine_end_request_t request = { .caller = erx_fiasco_thread_self()->index,
	    .res = res, .how = how };
	erx_fiasco_reply_t reply;

	return (erx_fiasco_service_call(ERX_FIASCO_CALL_MACHINE_END, &request, sizeof(request), &reply));
}
