/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

/*
 * The caller's side of the service's calls: each stub fills its request's layout
 * from abi/erx_abi.txt and sends it through the root's gate. No address crosses
 * except as a value.
 */

#include <stddef.h>
#include <stdint.h>

#include <l4/sys/ipc.h>
#include <l4/sys/utcb.h>

#include "erx/abi.h"
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
erx_machine_end(uint64_t res, uint32_t how)
{
	const erx_fiasco_machine_end_request_t request = { .caller = erx_fiasco_thread_self()->index,
	    .res = res, .how = how };
	erx_fiasco_reply_t reply;

	return (erx_fiasco_service_call(ERX_FIASCO_CALL_MACHINE_END, &request, sizeof(request), &reply));
}
