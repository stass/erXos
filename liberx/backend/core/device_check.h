/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

#ifndef ERX_BACKEND_DEVICE_CHECK_H
#define ERX_BACKEND_DEVICE_CHECK_H

#include <stdatomic.h>
#include <stdint.h>

#include "erx/abi.h"

/*
 * What is wrong with a device-memory or entropy request whatever a backend then does
 * with it, in one place so that both backends refuse the same requests the same way
 * (docs/design-stopgap.md, "The call table"), and the store that keeps a result to its
 * length. The native service runs the checks on words another task sent.
 */

_Static_assert(ERX_ENTROPY_BYTES_MAX <= ERX_UTCB_BYTES_MAX, "entropy's bytes fit the UTCB's mr");

static inline int
erx_backend_physical_check(uint64_t base, uint64_t size, uint32_t attr)
{
	uint64_t end;

	if (attr != ERX_MEM_ATTR_DEVICE || size == 0 || ((base | size) & (ERX_PAGE_SIZE - 1)) != 0 ||
	    __builtin_add_overflow(base, size, &end))
		return (ERX_EINVAL);
	return (ERX_OK);
}

static inline int
erx_backend_contiguous_check(uint64_t size)
{
	if (size == 0 || (size & (ERX_PAGE_SIZE - 1)) != 0 || size > ERX_MEM_CONTIGUOUS_MAX)
		return (ERX_EINVAL);
	return (ERX_OK);
}

static inline int
erx_backend_entropy_read_check(uint32_t len)
{
	return (len > ERX_ENTROPY_BYTES_MAX ? ERX_EINVAL : ERX_OK);
}

static inline int
erx_backend_entropy_add_check(uint32_t len, uint32_t flags)
{
	if (len > ERX_ENTROPY_BYTES_MAX || (flags & ~(uint32_t)ERX_ENTROPY_CREDIT) != 0)
		return (ERX_EINVAL);
	return (flags != 0 ? ERX_ENOTSUP : ERX_OK);
}

/*
 * Stores the bytes of a word that a result of len bytes holds, at byte offset at (a
 * multiple of 8) of the UTCB's mr, leaving every byte from len on as it was.
 */
static inline void
erx_backend_mr_put_bytes(erx_utcb_t *utcb, uint32_t at, uint64_t value, uint32_t len)
{
	const uint32_t word = at / sizeof(uint64_t);
	uint64_t mask;

	if (at >= len)
		return;
	if (len - at >= sizeof(uint64_t)) {
		atomic_store(&utcb->mr[word], value);
		return;
	}
	mask = (UINT64_C(1) << ((len - at) * 8)) - 1;
	atomic_store(&utcb->mr[word], (atomic_load(&utcb->mr[word]) & ~mask) | (value & mask));
}

#endif /* ERX_BACKEND_DEVICE_CHECK_H */
