/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

#ifndef LIBERX_SYSTEM_DOM_APPLY_H
#define LIBERX_SYSTEM_DOM_APPLY_H

#include "erx/abi.h"
#include "erx/cdefs.h"
#include "erx/dom.h"
#include "erx/dom_lib.h"

/*
 * The apply phase of a creation plan the core made against lib's view, for
 * the library's own entries alone: erx_dom_lib_create with a request's plan
 * and erx_dom_lib_configured (dom_boot.c) with a manifest row's. Applies each
 * step in order and records the plan in the view; on a refused step every
 * applied one is undone and the step's status is returned with *created
 * untouched.
 */
erx_status_t	erx_dom_lib_apply(erx_dom_lib_t *, const erx_dom_plan_t *,
		    erx_dom_created_t *created) ERX_WARN_UNUSED_RESULT;

#endif /* LIBERX_SYSTEM_DOM_APPLY_H */
