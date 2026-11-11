/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

#ifndef ERX_BACKEND_BOOT_MANIFEST_H
#define ERX_BACKEND_BOOT_MANIFEST_H

#include <stdbool.h>
#include <stddef.h>

#include "erx/abi.h"
#include "erx/boot_words.h"
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
 * which the root hands that ERTS so that erx_device can open it (docs/design-stopgap.md,
 * "Device records"). A device of a row of erx/device_kinds.h is given: the root makes its
 * window, line and memory objects at boot, as a holder's creation makes them, and hands
 * their handles as -erx given (erx_boot_given_words), so a device that does DMA has one
 * form in every domain. The host link's UART, which does no DMA, is the one physical
 * record, -erx device ROLE PERIPHERAL BASE SIZE LINE (erx_boot_device_words). role and
 * peripheral point at a row's names, and the numbers are the manifest's device entry. A
 * manifest whose units hold no such device has no record: a missing disk is a normal
 * state. The host link's UART gives a record only when the boot asks for the host link,
 * with erx.hostlink=1 on the kernel command line.
 */
#define ERX_BOOT_DEVICES_MAX	8

typedef struct erx_boot_device {
	const char	*role;		/* the record's role word: "block", "net" or "hostlink" */
	const char	*peripheral;	/* the peripheral's name in the CMSIS-SVD source */
	bool		given;		/* a row of erx/device_kinds.h; false for the host link's UART */
	uint64_t	base;		/* the register window */
	uint64_t	size;
	uint32_t	line;		/* the interrupt, as the platform's controller numbers it */
	uint64_t	dma_memory;	/* a given device's memory for the boot, whole pages; 0 for none */
} erx_boot_device_t;

/*
 * The pages that hold a device's registers, which its window object covers, and where the
 * registers start in them: the OFFSET of its -erx given record.
 */
typedef struct erx_boot_window {
	uint64_t	base;		/* the first page's physical address */
	uint64_t	size;		/* whole pages, from base through the registers' last byte */
	uint64_t	offset;		/* the registers' base less the first page's */
} erx_boot_window_t;

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

/*
 * Fills *result, or returns false and names the check that refused the bytes in *reason.
 * hostlink is whether the boot asks for the host link; without it the host link's UART gives
 * no device record.
 */
bool	erx_boot_manifest_read(const uint8_t *bytes, size_t length, bool hostlink, erx_boot_manifest_t *result,
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
 * Writes a physical record's words, -erx device ROLE PERIPHERAL BASE SIZE LINE with the
 * numbers in decimal, each word ended by NUL, into words, and returns their whole length.
 * Returns 0, having written nothing past capacity, when they do not fit. Only a device that
 * is not given has this record; a given one's is -erx given (erx_boot_device_given).
 */
size_t	erx_boot_device_words(const erx_boot_device_t *device, char *words, size_t capacity);

/*
 * The pages of the device's registers into *window; false, writing nothing, for registers
 * that are empty or end past the top of the address space.
 */
bool	erx_boot_device_window(const erx_boot_device_t *device, erx_boot_window_t *window);

/*
 * A device given to a holder domain, as its creation installed it (docs/design-stopgap.md,
 * "Boot information"): the values of its objects in the holder's table, which the holder's
 * device NIF opens it by. window and line are its register window's and its line's IRQ
 * object's; offset and size place its registers in the window; memory is its contiguous
 * memory's, ERX_CAP_NULL with memory_size 0 for none.
 */
typedef struct erx_boot_given {
	const char	*role;		/* erx/device_kinds.h's role word */
	const char	*peripheral;	/* and its CMSIS-SVD peripheral */
	uint64_t	window;
	uint64_t	offset;
	uint64_t	size;
	uint64_t	line;
	uint64_t	memory;
	uint64_t	memory_size;
} erx_boot_given_t;

/*
 * The given record of a device the root gives itself (docs/design-stopgap.md, "Device
 * records"): the device's names and register size, the offset of its window (from
 * erx_boot_device_window), and the handles of the objects the root made for it, its
 * register window, its line's IRQ object and its contiguous memory. A device without
 * dma_memory has no memory: the record names ERX_CAP_NULL, whatever memory_handle is.
 */
erx_boot_given_t	erx_boot_device_given(const erx_boot_device_t *device, const erx_boot_window_t *window,
	    uint64_t window_handle, uint64_t line_handle, uint64_t memory_handle);

/*
 * Writes -erx given ROLE PERIPHERAL WINDOW_H OFFSET SIZE LINE_H MEM_H MEM_SIZE, the numbers in
 * decimal and each word ended by NUL, into words, and returns their whole length; 0, having
 * written nothing past capacity, when they do not fit, which ERX_BOOT_GIVEN_WORDS_MAX bytes
 * (erx/boot_words.h) always do for names within ERX_BOOT_NAME_WORD_MAX.
 */
size_t	erx_boot_given_words(const erx_boot_given_t *given, char *words, size_t capacity);

/*
 * Writes -erx boot VALUE SLOT by the names of include/erx/core/boot_pair.h into words, and
 * returns their whole length; 0 for a value or slot that has no name, or words that do not
 * fit, which ERX_BOOT_PAIR_WORDS_MAX bytes always do.
 */
size_t	erx_boot_pair_words(uint32_t value, uint32_t slot, char *words, size_t capacity);

/*
 * Writes -erx build ID, the boot image's build identifier in decimal, into words, and
 * returns their whole length; 0 for words that do not fit, which ERX_BOOT_BUILD_WORDS_MAX
 * bytes always do. init reads an -erx word's values as terms, so a value must scan as one,
 * which hexadecimal digits do not (2255e43f is an illegal integer); a decimal number always
 * does. The root writes it into the system domain's boot page and the domain library into
 * every other domain's, so each domain of the image names the same build.
 */
size_t	erx_boot_build_words(uint64_t build_id, char *words, size_t capacity);

#endif /* ERX_BACKEND_BOOT_MANIFEST_H */
