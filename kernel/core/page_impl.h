/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

#ifndef ERX_PAGE_IMPL_H
#define ERX_PAGE_IMPL_H

/*
 * The page funnel's records. Only kernel/core/page.c includes this file
 * (and the funnel's host tests), which the page-records-private chokepoint
 * enforces, so a page's link and stamp and the released list are written
 * only in page.c.
 *
 * The page record holds what the funnel owns. The reference count, the
 * flags and the owner join it with the cores that use them.
 */

#include "erx/page.h"

struct erx_page {
	erx_page_t	*next;		/* the next page on its chain */
	uint64_t	 stamp;		/* on the released list: its batch's
					 * stamp from erx_grace_retire */
};

struct erx_released {
	erx_plist_t	 list;		/* batches in append order; stamps never
					 * decrease along it; under its lock */
	erx_grace_t	*tracker;	/* stamps every batch; fixed */
};

#endif /* ERX_PAGE_IMPL_H */
