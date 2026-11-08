/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

#ifndef ERX_GRACE_IMPL_H
#define ERX_GRACE_IMPL_H

/*
 * The grace tracker's record. Only kernel/core/grace.c includes this file
 * (and the tracker's host tests), which the grace-records-private
 * chokepoint enforces, so the counts are written only in grace.c.
 */

#include <stdatomic.h>

#include "erx/grace.h"

struct erx_grace {
	uint64_t	 current;	/* the newest period started; under the
					 * lock */
	_Atomic uint64_t completed;	/* the newest period completed: written
					 * under the lock, read without it */
	uint64_t	 awaited;	/* CPUs the current period has not
					 * heard from; under the lock */
	uint64_t	 online;	/* CPUs online, which the next period
					 * awaits; under the lock */
	bool		 pending;	/* the next period is requested; under
					 * the lock */
};

#endif /* ERX_GRACE_IMPL_H */
