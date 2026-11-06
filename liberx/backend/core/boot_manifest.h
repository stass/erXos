/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

#ifndef ERX_BACKEND_BOOT_MANIFEST_H
#define ERX_BACKEND_BOOT_MANIFEST_H

#include <stdbool.h>
#include <stddef.h>

#include "erx/abi.h"
#include "liberx/backend/core/boot_info.h"

/*
 * What of the system manifest reaches the boot information page, the same on both
 * entries (docs/design-stopgap.md, "Boot information"): the node name, the system's
 * arguments, the projection of system_runtime_limits, the console and the device
 * records. Pure, over the bytes handed in.
 */

/* system@, then an identifier of at most 63 bytes. */
#define ERX_BOOT_NODE_MAX	(sizeof("system@") - 1 + 63)

/* The manifest's device entry for machine.console; size 0 when no entry names it. */
typedef struct erx_boot_console {
	uint64_t	base;
	uint64_t	size;
	uint32_t	line;
} erx_boot_console_t;

/*
 * A device record: a device of a unit the system domain holds, of a kind its ERTS drives,
 * which the root hands that ERTS as -erx device ROLE PERIPHERAL BASE SIZE LINE DMA_MEMORY
 * so that erx_device can open it (docs/design-stopgap.md, "Device records"). The kinds
 * are the rows of device_kinds in boot_manifest.c; role and peripheral point at a row's
 * names, and the numbers are the manifest's device entry. A manifest whose units hold no
 * such device has no record: a missing disk is a normal state.
 */
#define ERX_BOOT_DEVICES_MAX	8
/* -erx device, two names of at most 15 bytes, four numbers of at most 20 digits, each word with its NUL. */
#define ERX_BOOT_DEVICE_WORDS_MAX	(sizeof("-erx") + sizeof("device") + 2 * 16 + 4 * 21)

typedef struct erx_boot_device {
	const char	*role;		/* the record's role word: "block" */
	const char	*peripheral;	/* the peripheral's name in the CMSIS-SVD source */
	uint64_t	base;		/* the register window */
	uint64_t	size;
	uint32_t	line;		/* the interrupt, as the platform's controller numbers it */
	uint64_t	dma_memory;	/* bytes reserved for the device's DMA for the boot; 0 for none */
} erx_boot_device_t;

typedef struct erx_boot_manifest {
	char			node[ERX_BOOT_NODE_MAX];
	size_t			node_len;
	erx_boot_words_t	system_args;	/* points into the manifest's bytes */
	erx_runtime_limits_t	limits;
	erx_boot_console_t	console;
	erx_boot_words_t	console_path;	/* machine.console, into the manifest's bytes */
	erx_boot_device_t	devices[ERX_BOOT_DEVICES_MAX];
	size_t			device_count;
} erx_boot_manifest_t;

/* Fills *result, or returns false and names the check that refused the bytes in *reason. */
bool	erx_boot_manifest_read(const uint8_t *bytes, size_t length, erx_boot_manifest_t *result,
	    const char **reason);

/*
 * Whether the manifest's console is the UART /chosen/stdout-path names
 * (docs/design-system.md, "Devices"): stdout_path is that node's full path, as
 * bootstrap resolved it, and the two paths match whole. An empty stdout_path, a
 * tree that names no node, matches no console.
 */
bool	erx_boot_console_matches(const erx_boot_manifest_t *manifest, const char *stdout_path,
	    size_t stdout_len);

/*
 * Writes the record's words, -erx device ROLE PERIPHERAL BASE SIZE LINE DMA_MEMORY with the
 * numbers in decimal, each word ended by NUL, into words, and returns their whole length.
 * Returns 0, having written nothing past capacity, when they do not fit.
 */
size_t	erx_boot_device_words(const erx_boot_device_t *device, char *words, size_t capacity);

#endif /* ERX_BACKEND_BOOT_MANIFEST_H */
