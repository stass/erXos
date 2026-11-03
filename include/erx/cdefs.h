/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

#ifndef ERX_CDEFS_H
#define ERX_CDEFS_H

#if !defined(__clang__) && !defined(__GNUC__)
#error "erXos requires a supported Clang or GCC compiler"
#endif

#define ERX_UNUSED __attribute__((__unused__))
#define ERX_WARN_UNUSED_RESULT __attribute__((__warn_unused_result__))

#endif /* ERX_CDEFS_H */
