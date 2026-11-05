/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

/*
 * The root service's decoder, pure. Each request's word count is the size of its
 * layout in abi/erx_abi.txt, which is also what the stub sends, so the two cannot
 * disagree. In order: a label naming no live task is dropped; a fault is not a
 * request; a call this backend has no row for is ERX_ENOTSUP; an unknown number, a
 * word count the ABI does not give and a thread index past the table are ERX_EINVAL.
 */

#include <stddef.h>
#include <stdint.h>

#include "erx/abi.h"
#include "liberx/backend/fiasco/service_wire.h"

_Static_assert(sizeof(erx_fiasco_vm_map_request_t) / sizeof(uint64_t) == ERX_FIASCO_WIRE_WORDS_MAX,
    "the longest request");

uint32_t
erx_fiasco_wire_words(int64_t number)
{
	switch (number) {
	case ERX_CALL_DEBUG_LOG:
		return (sizeof(erx_fiasco_debug_log_request_t) / sizeof(uint64_t));
	case ERX_FIASCO_CALL_TASK_WRITE:
		return (sizeof(erx_fiasco_task_write_request_t) / sizeof(uint64_t));
	case ERX_FIASCO_CALL_THREAD_CREATE:
		return (sizeof(erx_fiasco_thread_create_request_t) / sizeof(uint64_t));
	case ERX_FIASCO_CALL_THREAD_START:
		return (sizeof(erx_fiasco_thread_start_request_t) / sizeof(uint64_t));
	case ERX_FIASCO_CALL_THREAD_SET_AFFINITY:
		return (sizeof(erx_fiasco_thread_set_affinity_request_t) / sizeof(uint64_t));
	case ERX_FIASCO_CALL_THREAD_REAP:
		return (sizeof(erx_fiasco_thread_reap_request_t) / sizeof(uint64_t));
	case ERX_FIASCO_CALL_VM_RESERVE:
	case ERX_FIASCO_CALL_SPACE_PROTECT:
		return (sizeof(erx_fiasco_vm_flagged_request_t) / sizeof(uint64_t));
	case ERX_FIASCO_CALL_VM_COMMIT:
	case ERX_FIASCO_CALL_VM_DECOMMIT:
	case ERX_FIASCO_CALL_VM_RELEASE:
		return (sizeof(erx_fiasco_vm_range_request_t) / sizeof(uint64_t));
	case ERX_FIASCO_CALL_MACHINE_END:
		return (sizeof(erx_fiasco_machine_end_request_t) / sizeof(uint64_t));
	case ERX_FIASCO_CALL_IRQ_CREATE:
		return (sizeof(erx_fiasco_irq_create_request_t) / sizeof(uint64_t));
	case ERX_FIASCO_CALL_IRQ_BIND:
		return (sizeof(erx_fiasco_irq_bind_request_t) / sizeof(uint64_t));
	case ERX_FIASCO_CALL_IRQ_ACK:
	case ERX_FIASCO_CALL_IRQ_TRIGGER:
		return (sizeof(erx_fiasco_irq_request_t) / sizeof(uint64_t));
	case ERX_FIASCO_CALL_TIME_SET_WALL:
		return (sizeof(erx_fiasco_time_set_wall_request_t) / sizeof(uint64_t));
	case ERX_FIASCO_CALL_MEM_CREATE:
		return (sizeof(erx_fiasco_mem_create_request_t) / sizeof(uint64_t));
	case ERX_FIASCO_CALL_MEM_CREATE_PHYSICAL:
		return (sizeof(erx_fiasco_mem_physical_request_t) / sizeof(uint64_t));
	case ERX_FIASCO_CALL_MEM_CREATE_CONTIGUOUS:
		return (sizeof(erx_fiasco_mem_contiguous_request_t) / sizeof(uint64_t));
	case ERX_FIASCO_CALL_MEM_DMA_ADDR:
		return (sizeof(erx_fiasco_mem_dma_request_t) / sizeof(uint64_t));
	case ERX_FIASCO_CALL_ENTROPY_READ:
		return (sizeof(erx_fiasco_entropy_read_request_t) / sizeof(uint64_t));
	case ERX_FIASCO_CALL_ENTROPY_ADD:
		return (sizeof(erx_fiasco_entropy_add_request_t) / sizeof(uint64_t));
	case ERX_FIASCO_CALL_VM_MAP:
		return (sizeof(erx_fiasco_vm_map_request_t) / sizeof(uint64_t));
	case ERX_FIASCO_CALL_SPACE_CREATE:
		return (sizeof(erx_fiasco_space_create_request_t) / sizeof(uint64_t));
	case ERX_FIASCO_CALL_IMAGE_MAP:
		return (sizeof(erx_fiasco_image_map_request_t) / sizeof(uint64_t));
	case ERX_FIASCO_CALL_SPACE_STOP:
		return (sizeof(erx_fiasco_space_stop_request_t) / sizeof(uint64_t));
	case ERX_FIASCO_CALL_TASK_JOIN:
		return (sizeof(erx_fiasco_task_join_request_t) / sizeof(uint64_t));
	default:
		return (0);
	}
}

erx_fiasco_wire_decoded_t
erx_fiasco_wire_decode(const erx_fiasco_wire_input_t *input)
{
	erx_fiasco_wire_decoded_t decoded = { .kind = ERX_FIASCO_WIRE_REFUSE, .status = ERX_EINVAL };
	const uint64_t task = input->label >> ERX_FIASCO_WIRE_LABEL_SHIFT;
	uint32_t expected;

	if (task >= 64 || ((input->live_mask >> task) & 1) == 0) {
		decoded.kind = ERX_FIASCO_WIRE_DROP;
		return (decoded);
	}
	decoded.task = (uint32_t)task;

	if (input->tag_label == ERX_FIASCO_WIRE_PAGE_FAULT) {
		if (input->words == ERX_FIASCO_WIRE_PAGE_FAULT_WORDS)
			decoded.kind = ERX_FIASCO_WIRE_FAULT_PAGE;
		return (decoded);
	}
	if (input->tag_label == ERX_FIASCO_WIRE_EXCEPTION) {
		if (input->words == ERX_FIASCO_WIRE_EXCEPTION_WORDS)
			decoded.kind = ERX_FIASCO_WIRE_FAULT_EXCEPTION;
		return (decoded);
	}
	expected = erx_fiasco_wire_words(input->tag_label);
	if (expected == 0 || input->words != expected || input->mr[0] >= ERX_FIASCO_THREADS_MAX)
		return (decoded);

	decoded.kind = ERX_FIASCO_WIRE_REQUEST;
	decoded.status = ERX_OK;
	decoded.call = (uint32_t)input->tag_label;
	decoded.caller = (uint32_t)input->mr[0];
	for (uint32_t index = 0; index < expected; index++)
		decoded.request[index] = input->mr[index];
	return (decoded);
}
