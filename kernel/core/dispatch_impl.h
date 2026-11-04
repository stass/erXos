/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

#ifndef ERX_DISPATCH_IMPL_H
#define ERX_DISPATCH_IMPL_H

#include "erx/core/dispatch.h"

/* A handler's view of its call; only erx_dispatch creates one. */
struct erx_sys_context {
	const erx_sys_caller_t	*caller;
};

#endif /* ERX_DISPATCH_IMPL_H */
