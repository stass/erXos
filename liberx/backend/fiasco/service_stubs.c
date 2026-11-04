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
#include <l4/sys/utcb.h>

#include "erx/abi.h"
#include "liberx/backend/api.h"
#include "liberx/backend/core/device_check.h"
#include "liberx/backend/fiasco/service.h"
#include "liberx/backend/fiasco/thread.h"
#include "liberx/backend/fiasco/vm.h"

static int stub_range(uint32_t, uint64_t, uint64_t);
static int stub_flagged(uint32_t, uint64_t, uint64_t, uint64_t, uint64_t *);

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
	return ((int)reply->status);
}

static int
stub_range(uint32_t number, uint64_t addr, uint64_t size)
{
	const erx_fiasco_vm_range_request_t request = { .caller = erx_fiasco_thread_self()->index,
	    .addr = addr, .size = size };
	erx_fiasco_reply_t reply;

	return (erx_fiasco_service_call(number, &request, sizeof(request), &reply));
}

static int
stub_flagged(uint32_t number, uint64_t addr, uint64_t size, uint64_t flags, uint64_t *first)
{
	const erx_fiasco_vm_flagged_request_t request = { .caller = erx_fiasco_thread_self()->index,
	    .addr = addr, .size = size, .flags = flags };
	erx_fiasco_reply_t reply;
	const int status = erx_fiasco_service_call(number, &request, sizeof(request), &reply);

	if (status == ERX_OK && first != NULL)
		*first = reply.first;
	return (status);
}

int
erx_vm_reserve(uint64_t addr, uint64_t size, uint32_t flags, uint64_t *reserved)
{
	return (stub_flagged(ERX_FIASCO_CALL_VM_RESERVE, addr, size, flags, reserved));
}

int
erx_vm_commit(uint64_t addr, uint64_t size)
{
	return (stub_range(ERX_FIASCO_CALL_VM_COMMIT, addr, size));
}

int
erx_vm_decommit(uint64_t addr, uint64_t size)
{
	return (stub_range(ERX_FIASCO_CALL_VM_DECOMMIT, addr, size));
}

int
erx_vm_release(uint64_t addr, uint64_t size)
{
	return (stub_range(ERX_FIASCO_CALL_VM_RELEASE, addr, size));
}

int
erx_space_protect(uint64_t addr, uint64_t size, uint32_t prot)
{
	return (stub_flagged(ERX_FIASCO_CALL_SPACE_PROTECT, addr, size, prot, NULL));
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
erx_mem_create_contiguous(uint64_t budget, uint64_t resource, uint64_t size, uint64_t limit, uint64_t *mem)
{
	const erx_fiasco_mem_contiguous_request_t request = { .caller = erx_fiasco_thread_self()->index, .budget = budget,
	    .size = size, .limit = limit };
	erx_fiasco_reply_t reply;
	const int status = erx_fiasco_service_call(ERX_FIASCO_CALL_MEM_CREATE_CONTIGUOUS, &request, sizeof(request), &reply);

	(void)resource;
	if (status == ERX_OK)
		*mem = reply.first;
	return (status);
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

/* A reply holds two words, so a read asks for them until it has its bytes. */
int
erx_entropy_read(uint32_t len)
{
	const erx_fiasco_entropy_read_request_t request = { .caller = erx_fiasco_thread_self()->index };
	const int checked = erx_backend_entropy_read_check(len);
	erx_fiasco_reply_t reply;

	if (checked != ERX_OK)
		return (checked);
	for (uint32_t done = 0; done < len; done += 2 * sizeof(uint64_t)) {
		const int status = erx_fiasco_service_call(ERX_FIASCO_CALL_ENTROPY_READ, &request, sizeof(request), &reply);

		if (status != ERX_OK)
			return (status);
		erx_backend_mr_put_bytes(erx_utcb_self(), done, reply.first, len);
		erx_backend_mr_put_bytes(erx_utcb_self(), done + sizeof(uint64_t), reply.second, len);
	}
	return (ERX_OK);
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
erx_image_map(uint64_t space, uint64_t image, uint64_t entry, uint64_t *start)
{
	const erx_fiasco_image_map_request_t request = { .caller = erx_fiasco_thread_self()->index, .space = space,
	    .image = image, .entry = entry };
	erx_fiasco_reply_t reply;
	const int status = erx_fiasco_service_call(ERX_FIASCO_CALL_IMAGE_MAP, &request, sizeof(request), &reply);

	if (status == ERX_OK)
		*start = reply.first;
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
