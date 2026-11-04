/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

#ifndef ERX_FIASCO_PAGE_POOL_H
#define ERX_FIASCO_PAGE_POOL_H

#include <stdint.h>

/*
 * The pool of free pages (docs/design-stopgap.md, "The pool"). A page's identity
 * is its address in the window, and the free pages are a list threaded through
 * the pages themselves, so the pool costs no memory of its own. A free page
 * holds its link and whatever its last holder left; it is zeroed when taken, so
 * what a taker sees never depends on who held the page before.
 *
 * This core touches only the pages it is handed, so it builds for the host.
 */
typedef struct erx_fiasco_pool {
	uintptr_t	head;		/* first free page's address, or 0 */
	uint64_t	free_pages;
} erx_fiasco_pool_t;

/* Adds one page. No one may hold a mapping of it any more. */
void		erx_fiasco_pool_put(erx_fiasco_pool_t *, uintptr_t);

/* A zeroed page's window address, or 0 when the pool is empty. */
uintptr_t	erx_fiasco_pool_take(erx_fiasco_pool_t *);

#endif /* ERX_FIASCO_PAGE_POOL_H */
