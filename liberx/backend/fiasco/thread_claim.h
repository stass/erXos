/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

#ifndef ERX_FIASCO_THREAD_CLAIM_H
#define ERX_FIASCO_THREAD_CLAIM_H

#include <stdbool.h>
#include <stdint.h>

/*
 * Which thread index a create may take (docs/design-stopgap.md, "Claiming an
 * index"): the lowest whose record is free and whose UTCB's marker reads 0. The
 * kernel clears a marker some time after a deletion returns, and until then it
 * still writes that UTCB. The caller holds the thread lock across this and its
 * write of the record's state. used and marker read one index's state.
 */
typedef struct erx_fiasco_claim_view {
	bool		(*used)(void *, uint32_t);
	uint64_t	(*marker)(void *, uint32_t);
} erx_fiasco_claim_view_t;

/* Returns the index, or limit when none in first..limit-1 is claimable. */
uint32_t erx_fiasco_thread_claim_pick(const erx_fiasco_claim_view_t *, void *, uint32_t first, uint32_t limit);

#endif /* ERX_FIASCO_THREAD_CLAIM_H */
