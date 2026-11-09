/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

/*
 * A domain's crash area, as ERTS writes it (docs/design-runtime.md, "Data
 * model" and "Crash handling"). The domain library hands every domain but
 * the system domain a memory object of ERX_CRASH_SIZE bytes, named by the
 * boot information page; erx_crash_area_init maps it writable into the
 * runtime's own space. On a fatal exit erts_exit_vv puts the slogan in the
 * header (erx_crash_area_begin), erl_crash_dump_v writes the dump text
 * after it through erx_crash_area_write, and the exit path then stops the
 * space with ERX_EXIT_CRASH (erx_crash_area_stop), which completes the
 * header first: length, flags and version, then the magic last with a
 * release store, so a header with the magic is whole. The system domain
 * has no area and keeps stock ERTS's dump file and exit.
 */

#ifndef ERX_CRASH_AREA_H
#define ERX_CRASH_AREA_H

#include <stdarg.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

/* Maps the boot page's crash area, if the domain has one; a failure is reported and leaves none. */
void	erx_crash_area_init(void);
/* Whether a crash area is mapped, so a dump has somewhere to go. */
int	erx_crash_area_mapped(void);
/* The slogan: fmt formatted with args, cut at its first newline and at 231 bytes. */
void	erx_crash_area_begin(const char *fmt, va_list args);
/*
 * A dump writer (fmtfn_t) and its close, for erl_crash_dump_v. Text past the
 * area's end is dropped, the dump is marked truncated and the space stops.
 */
int	erx_crash_area_write(void *arg, char *buf, size_t len);
void	erx_crash_area_close(void *arg);
/*
 * In a domain other than the system domain, completes the header and stops
 * the space with ERX_EXIT_CRASH, with or without an area; returns only in
 * the system domain, or if the stop failed, so the caller's stock exit
 * follows.
 */
void	erx_crash_area_stop(void);
/* A fatal end that bypasses erts_exit, a failed assertion: the slogan from fmt, then the stop. */
void	erx_crash_area_fail(const char *fmt, ...);

#ifdef __cplusplus
}
#endif

#endif /* ERX_CRASH_AREA_H */
