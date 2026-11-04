/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

#ifndef ERX_HOSTED_LOG_H
#define ERX_HOSTED_LOG_H

#include "erx/abi.h"

/* The calling thread's UTCB, as the erx backend's erx_utcb_self returns it. */
erx_utcb_t *erx_utcb_self(void);

#endif /* ERX_HOSTED_LOG_H */
