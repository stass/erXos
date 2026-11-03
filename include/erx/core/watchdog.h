/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

#ifndef ERX_CORE_WATCHDOG_H
#define ERX_CORE_WATCHDOG_H

/*
 * The watchdog core's configuration, as the stopgap's C++ glue sees it
 * (docs/design-stopgap.md, "Interfaces"). A header of include/erx/core/
 * is the seam between the C17 cores and Fiasco: it compiles as C17 and
 * as C++, and includes nothing but the freestanding standard headers and
 * other headers of include/erx/core/, because the build gives the glue
 * this directory alone. The rest of the watchdog's interface is in
 * erx/watchdog.h, which includes this file.
 */

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* Why a value of erx.watchdog= was refused; the defaults are used instead. */
typedef enum erx_watchdog_parse_status {
	ERX_WATCHDOG_PARSE_OK = 0,
	ERX_WATCHDOG_PARSE_FIELDS,	/* not three comma-separated fields */
	ERX_WATCHDOG_PARSE_EMPTY,	/* a field without digits */
	ERX_WATCHDOG_PARSE_DIGIT,	/* a byte other than a digit or comma */
	ERX_WATCHDOG_PARSE_OVERFLOW,	/* a field beyond 32 bits */
	ERX_WATCHDOG_PARSE_PERIOD,	/* P outside its bounds */
	ERX_WATCHDOG_PARSE_DEADLINE,	/* D outside 2P to its maximum */
	ERX_WATCHDOG_PARSE_BOOT		/* B outside D to its maximum */
} erx_watchdog_parse_status_t;

typedef struct erx_watchdog_config erx_watchdog_config_t;

/* erx.watchdog=P,D,B, in seconds; the machine page carries all three. */
struct erx_watchdog_config {
	uint32_t	period_s;
	uint32_t	deadline_s;
	uint32_t	boot_s;
};

erx_watchdog_config_t erx_watchdog_config_default(void);
/* The attribute is spelled out: erx/cdefs.h is outside this directory. */
erx_watchdog_parse_status_t erx_watchdog_parse(const char *, size_t,
    erx_watchdog_config_t *) __attribute__((__warn_unused_result__));
const char *erx_watchdog_parse_reason(erx_watchdog_parse_status_t);

#ifdef __cplusplus
}
#endif

#endif /* ERX_CORE_WATCHDOG_H */
