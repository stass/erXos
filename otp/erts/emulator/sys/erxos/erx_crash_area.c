/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

/*
 * The writer of a domain's crash area; erx_crash_area.h has the protocol.
 * The exit path runs on one thread with every other thread blocked
 * (erts_exit_vv lets one thread through, erl_crash_dump_v blocks the
 * rest), so the writer's state needs no lock. The area is the domain's
 * own memory, which the system domain copies out and checks field by
 * field after the space has stopped (liberx/system/dom_dump.c). The
 * writer keeps its position in its own static state and never reads the
 * area back.
 */

#ifdef HAVE_CONFIG_H
#include "config.h"
#endif

#include "sys.h"
#include "erl_printf.h"
#include "liberx/backend/api.h"
#include "erx/abi.h"
#include "erx_crash_area.h"

/* The text after the header. */
#define CRASH_TEXT_ROOM	((size_t)ERX_CRASH_SIZE - ERX_DUMP_HEADER_SIZE)

static erx_dump_header_t *area;		/* NULL: no area is mapped */
static size_t stored;			/* bytes of text stored after the header */
static int truncated;			/* text past the area's end was dropped */
static int completed;			/* the header holds the magic */

void
erx_crash_area_init(void)
{
    const uint64_t mem = erx_runtime_boot()->crash_area.raw;
    uint64_t addr = 0;
    int status;

    if (erx_runtime_is_system() || mem == ERX_CAP_NULL)
	return;
    status = erx_vm_reserve(ERX_CAP_SELF, 0, ERX_CRASH_SIZE, 0, &addr);
    if (status == ERX_OK) {
	status = erx_vm_map(ERX_CAP_SELF, addr, ERX_CRASH_SIZE, mem, 0, ERX_PROT_RW);
	if (status != ERX_OK)
	    (void) erx_vm_release(ERX_CAP_SELF, addr, ERX_CRASH_SIZE);
    }
    if (status != ERX_OK) {
	fprintf(stderr, "erx: the crash area is not mapped (%d); a crash leaves no dump\n", status);
	return;
    }
    area = (erx_dump_header_t *) (uintptr_t) addr;
}

int
erx_crash_area_mapped(void)
{
    return area != NULL;
}

void
erx_crash_area_begin(const char *fmt, va_list args)
{
    char *slogan, *newline;

    if (area == NULL || fmt == NULL)
	return;
    slogan = (char *) area->slogan;
    (void) erts_vsnprintf(slogan, ERX_DUMP_SLOGAN, fmt, args);
    slogan[ERX_DUMP_SLOGAN - 1] = '\0';
    newline = strchr(slogan, '\n');
    if (newline != NULL)
	*newline = '\0';
}

/* Writes the header's fields, then the magic, once. */
static void
crash_area_complete(void)
{
    if (area == NULL || completed)
	return;
    area->version = ERX_DUMP_VERSION;
    area->flags = truncated ? ERX_DUMP_TRUNCATED : 0;
    area->pad = 0;
    area->length = stored;
    __atomic_store_n(&area->magic, ERX_DUMP_MAGIC, __ATOMIC_RELEASE);
    completed = 1;
}

int
erx_crash_area_write(void *arg, char *buf, size_t len)
{
    const size_t room = CRASH_TEXT_ROOM - stored;
    const size_t taken = len < room ? len : room;

    (void) arg;
    if (completed)
	return -1;
    memcpy((char *) area + ERX_DUMP_HEADER_SIZE + stored, buf, taken);
    stored += taken;
    if (taken < len) {
	truncated = 1;
	/* Ends the process: the rest of the dump has nowhere to go. Returns only if the stop failed. */
	erx_crash_area_stop();
	return -1;
    }
    /* len fit in the room left, which is less than INT_MAX. */
    return (int) len;
}

void
erx_crash_area_close(void *arg)
{
    (void) arg;
    crash_area_complete();
}

void
erx_crash_area_stop(void)
{
    if (erx_runtime_is_system())
	return;
    crash_area_complete();
    (void) erx_space_stop(ERX_CAP_SELF, ERX_EXIT_CRASH);
}

void
erx_crash_area_fail(const char *fmt, ...)
{
    va_list args;

    va_start(args, fmt);
    erx_crash_area_begin(fmt, args);
    va_end(args);
    erx_crash_area_stop();
}
