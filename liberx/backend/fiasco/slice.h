/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

#ifndef ERX_FIASCO_SLICE_H
#define ERX_FIASCO_SLICE_H

#include <stdint.h>

#include "erx/abi.h"
#include "erx/cdefs.h"

/*
 * The service's bodies of erx_image_slice, erx_mem_copy and a task's erx_release_entry
 * (slice.c). caller and task are the calling task; each result is the call table's.
 */

/*
 * From the root alone (ERX_ENOTSUP elsewhere): entries [first, first + count) of the
 * archive erx_fiasco_task_set_archive named, as a memory object charged to budget.
 * No entry, a run past the index, or a run without a page of its own ERX_ERANGE.
 */
int	erx_fiasco_slice_create_body(uint32_t caller, const erx_fiasco_image_slice_request_t *request, uint64_t *slice)
	    ERX_WARN_UNUSED_RESULT;
/* One request of a copy between two memory objects the caller holds: erx_fiasco_vm_object_copy's results. */
int	erx_fiasco_mem_copy_body(uint32_t caller, const erx_fiasco_mem_copy_request_t *request, uint64_t *done)
	    ERX_WARN_UNUSED_RESULT;
/*
 * The index-th entry of the slice release names: a memory object that is not a slice
 * ERX_ETYPE, an index past the slice or a piece past the path ERX_ERANGE, a file
 * whose check fails ERX_ECORRUPT.
 */
int	erx_fiasco_release_entry_body(uint32_t task, const erx_fiasco_release_entry_request_t *request,
	    erx_fiasco_reply_t *reply) ERX_WARN_UNUSED_RESULT;

#endif /* ERX_FIASCO_SLICE_H */
