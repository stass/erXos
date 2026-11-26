/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

#ifndef ERX_CORE_BOOT_ARGS_H
#define ERX_CORE_BOOT_ARGS_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#include "erx/core/watchdog.h"

#ifdef __cplusplus
extern "C" {
#endif

/*
 * The kernel command line (docs/design-fiasco.md, "The command line"), split on spaces.
 * A word that does not start with erx. is a boot loader's, and ignored. Words of erx. are
 * erx.watchdog=P,D,B, erx.det=1, erx.group_report=1, erx.hostlink=1, erx.trace=0 or 1 and erx.arg=WORD;
 * anything else starting with erx. is a mistake that would otherwise go unseen, so it refuses the boot like a
 * malformed one. The kernel and the root read the line with this one reader, a C17 core of both.
 */
typedef struct erx_boot_args {
	bool			 det;
	bool			 group_report;	/* the group's report on the console (park_report.c) */
	bool			 hostlink;	/* the host link's device record (boot_manifest.c) */
	bool			 have_trace;	/* an erx.trace word, the last one in trace */
	bool			 trace;
	bool			 have_watchdog;
	erx_watchdog_config_t	 watchdog;	/* the last one, with have_watchdog */
	uint32_t		 arg_count;	/* erx.arg words */
	uint32_t		 arg_bytes;	/* what they take on the page, each one's NUL included */
	const char		*refused;	/* after a refusal, the word's name: not NUL-ended */
	size_t			 refused_len;
} erx_boot_args_t;

bool	erx_boot_args_parse(const char *bytes, size_t length, erx_boot_args_t *out);
/* The next erx.arg word's value, not NUL-ended, of a line erx_boot_args_parse accepted. Start with cursor 0. */
bool	erx_boot_args_next_arg(const char *bytes, size_t length, size_t *cursor, const char **word, size_t *word_len);

/*
 * Whether the kernel's trace rings run this boot (docs/design-fiasco.md, "The kernel's trace rings"):
 * the line's erx.trace if it has one, else on in a development build and off in a release build.
 */
bool	erx_boot_args_trace(const erx_boot_args_t *args, bool development);
/*
 * The same decision from the line's bytes, as the kernel and every root make it: a line the
 * reader refuses leaves the rings off.
 */
bool	erx_boot_line_trace(const char *bytes, size_t length, bool development);

#ifdef __cplusplus
}
#endif

#endif /* ERX_CORE_BOOT_ARGS_H */
