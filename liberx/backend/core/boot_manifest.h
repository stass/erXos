/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

#ifndef ERX_BACKEND_BOOT_MANIFEST_H
#define ERX_BACKEND_BOOT_MANIFEST_H

#include <stdbool.h>
#include <stddef.h>

#include "erx/abi.h"
#include "erx/core/dt.h"
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
	bool		line_shared;	/* another device-tree device of the manifest names line */
	uint32_t	clock;		/* the UART's clock in hertz, which its driver divides from */
} erx_boot_console_t;

/*
 * A device record: a device of a unit the system domain holds, of a kind its ERTS drives,
 * which the root hands that ERTS so that erx_device can open it (docs/design-stopgap.md,
 * "Device records"). A device of a row of erx/device_kinds.h is given: the root makes its
 * window, line and memory objects at boot, as a holder's creation makes them, and hands
 * their handles as -erx given (erx_boot_given_words), so a device that does DMA has one
 * form in every domain. The host link's UART, which does no DMA, is the one physical
 * record, -erx device ROLE PERIPHERAL BASE SIZE LINE MARK CLOCK (erx_boot_device_words). role
 * and peripheral point at a row's names, and the numbers are the manifest's device entry.
 * MARK, in every form, is shared when another device of the unit names the line and direct
 * otherwise (docs/design-shared-devices.md, "Lines inside a domain"), so no driver decides
 * whether its line is shared. A manifest whose units hold no such device has no record: a
 * missing disk is a normal state. The host link's UART gives a record only when the boot asks for the host link,
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
	bool		line_shared;	/* another device of its unit names line (docs/design-shared-devices.md) */
	uint32_t	clock;		/* the device's clock in hertz; 0 for a device whose driver reads none */
	uint64_t	dma_memory;	/* a given device's memory for the boot, whole pages; 0 for none */
	bool		network;	/* a row of the network role, whose record carries the tree's MAC */
	erx_boot_words_t path;		/* its device-tree path, into the manifest's bytes */
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
 * The page that holds the console's registers, which its driver maps first: the device NIF
 * maps the pages of a window, and the root hands the log to the console when a physical
 * object starts at this page (docs/design-stopgap.md, "The console"). 0, which turns the handoff
 * off, when no entry names the console or its registers lie in the first page.
 */
uint64_t	erx_boot_console_page(const erx_boot_manifest_t *manifest);

/*
 * Writes a physical record's words, -erx device ROLE PERIPHERAL BASE SIZE LINE MARK CLOCK with
 * the numbers in decimal and MARK direct or shared by line_shared, each word ended by NUL,
 * into words, and returns their whole length. Returns 0, having written nothing past
 * capacity, when they do not fit. Only a device that is not given has this record; a given
 * one's is -erx given (erx_boot_device_given).
 */
size_t	erx_boot_device_words(const erx_boot_device_t *device, char *words, size_t capacity);

/*
 * Writes the console's words, -erx console_uart BASE SIZE LINE MARK CLOCK, as
 * erx_boot_device_words writes a physical record's, into words, and returns their whole
 * length; 0, having written nothing past capacity, when they do not fit, which
 * ERX_BOOT_CONSOLE_WORDS_MAX bytes (erx/boot_words.h) always do.
 */
size_t	erx_boot_console_words(const erx_boot_console_t *console, char *words, size_t capacity);

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
 * memory's, ERX_CAP_NULL with memory_size 0 for none; clock is the device's clock in hertz,
 * 0 for a device whose driver reads none.
 */
typedef struct erx_boot_given {
	const char	*role;		/* erx/device_kinds.h's role word */
	const char	*peripheral;	/* and its CMSIS-SVD peripheral */
	uint64_t	window;
	uint64_t	offset;
	uint64_t	size;
	uint64_t	line;
	bool		line_shared;	/* the device's, which the record marks shared rather than direct */
	uint64_t	memory;
	uint64_t	memory_size;
	uint64_t	clock;
	/* The firmware's device tree marks its DMA cache-coherent (docs/design-device-tree.md). */
	bool		coherent;
	uint64_t	mac;		/* the tree's hardware address, 48 bits; 0 for none */
} erx_boot_given_t;

/*
 * The given record of a device the root gives itself (docs/design-stopgap.md, "Device
 * records"): the device's names and register size, the offset of its window (from
 * erx_boot_device_window), and the handles of the objects the root made for it, its
 * register window, its line's IRQ object and its contiguous memory. A device without
 * dma_memory, or whose memory_handle is ERX_CAP_NULL because erx_boot_dma_absent refused
 * it memory, has none: the record names ERX_CAP_NULL with MEM_SIZE 0. facts are the
 * firmware tree's for a row that asked (erx_boot_device_asks), or NULL for a row that
 * asked nothing. COHERENT is the facts' coherence for a row with DMA memory whose facts
 * have a DMA range, and 0 otherwise; MAC is the facts' address for a network row, and 0
 * otherwise.
 */
erx_boot_given_t	erx_boot_device_given(const erx_boot_device_t *device, const erx_boot_window_t *window,
	    const erx_dt_device_t *facts, uint64_t window_handle, uint64_t line_handle, uint64_t memory_handle);

/*
 * Writes -erx given ROLE PERIPHERAL WINDOW_H OFFSET SIZE LINE_H MARK MEM_H MEM_SIZE CLOCK COHERENT
 * MAC, the numbers in decimal, COHERENT 1 or 0, MARK direct or shared by line_shared, and each word ended by NUL, into
 * words, and returns their whole length; 0, having written nothing past capacity, when they
 * do not fit, which ERX_BOOT_GIVEN_WORDS_MAX bytes (erx/boot_words.h) always do for names
 * within ERX_BOOT_NAME_WORD_MAX.
 */
size_t	erx_boot_given_words(const erx_boot_given_t *given, char *words, size_t capacity);

/*
 * Whether the root asks the firmware's tree for a given device's facts
 * (docs/design-device-tree.md, "What each row asks"): a row with DMA memory asks for its
 * coherence and DMA range, a network row for its hardware address, and every other row
 * nothing. erx_boot_device_given reads only what the row asked from the facts.
 */
bool	erx_boot_device_asks(const erx_boot_device_t *device);

/*
 * The longest line erx_boot_tree_line writes: its fixed words, a node path of fewer than
 * ERX_PATH_MAX bytes, three addresses of 0x and 16 digits, and the newline.
 */
#define ERX_BOOT_TREE_LINE_MAX	(sizeof("erx: device tree: ") + ERX_PATH_MAX + \
	sizeof(": coherent 1 range ") + 3u * sizeof("0x0123456789abcdef") + sizeof(" mac present\n"))

/*
 * Writes the root's console line for a device that asked the tree (erx_boot_device_asks;
 * docs/design-device-tree.md, "The lines"), without a NUL, into line, and returns its
 * length: "erx: device tree: PATH:", then for a row with DMA memory " coherent C range CPU
 * BUS LAST" or " dma absent REASON", REASON being absent, the reason erx_boot_dma_absent gave
 * once the memory was made, or when absent is NULL the facts' own (erx_boot_dma_absent with
 * size 0), then
 * for a network row " mac present" or " mac absent", and a newline. PATH is the manifest's;
 * the numbers are the facts', addresses in hexadecimal; the reasons are fixed words, so no
 * byte of the tree reaches the line. Returns 0, having written nothing past capacity, for a
 * path that is not a node path (erx_boot_node_path_valid) or a line that does not fit, which
 * ERX_BOOT_TREE_LINE_MAX bytes always do for a path within ERX_PATH_MAX.
 */
size_t	erx_boot_tree_line(const erx_boot_device_t *device, const erx_dt_device_t *facts, const char *absent,
	    char *line, size_t capacity);

/*
 * Why a device the firmware's tree describes by facts gets no DMA memory at first, size
 * bytes, or NULL when it may have it (docs/design-device-tree.md, "Facts into records"):
 * the reader's reason when the facts have no DMA range ("no_node", "coherence", "cells",
 * "malformed", "ranges"); "offset" for a range whose bus addresses are not its CPU
 * addresses, since no memory object records the difference yet; and "outside" when the
 * memory does not lie whole inside the range. size 0 asks before the memory is made, so
 * only the facts are checked. Each reason is a fixed word the root may print.
 */
const char	*erx_boot_dma_absent(const erx_dt_device_t *facts, uint64_t first, uint64_t size);

/* The tree's hardware address as a 48-bit number, its first byte highest; 0 for none. */
uint64_t	erx_boot_mac_number(const erx_dt_device_t *facts);

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
