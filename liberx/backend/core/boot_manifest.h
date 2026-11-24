/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

#ifndef ERX_BACKEND_BOOT_MANIFEST_H
#define ERX_BACKEND_BOOT_MANIFEST_H

#include <stdbool.h>
#include <stddef.h>

#include "erx/abi.h"
#include "erx/abi_reader.h"
#include "erx/core/dt.h"
#include "erx/boot_words.h"
#include "liberx/backend/api.h"
#include "liberx/backend/core/boot_info.h"

/*
 * What of the system manifest reaches the boot information page, the same on both
 * entries (docs/design-fiasco.md, "Boot information"): the node name, the system's
 * arguments, the projection of system_runtime_limits, the console and the device
 * records. Pure, over the bytes handed in.
 */

/* system@, then an identifier of at most 63 bytes. */
#define ERX_BOOT_NODE_MAX	(sizeof("system@") - 1 + 63)

/*
 * The manifest's device entry for machine.console; all 0, kind NULL, when no entry names
 * it or its compatible string is in no row of erx_uart_kinds (erx/device_kinds.h).
 */
typedef struct erx_boot_console {
	/* Its row of erx_uart_kinds: the record's role word, then its CMSIS-SVD PERIPHERAL. */
	const struct erx_device_kind *kind;
	uint64_t	base;
	uint64_t	size;
	uint32_t	line;
	bool		line_shared;	/* another device-tree device of the manifest names line */
	uint32_t	clock;		/* the UART's clock in hertz, which its driver divides from */
} erx_boot_console_t;

/*
 * A device record: a device of a unit the system domain holds, of a kind its ERTS drives,
 * which the root hands that ERTS so that erx_device can open it (docs/design-fiasco.md,
 * "Device records"). A device of a row of erx/device_kinds.h is given: the root makes its
 * window, line and memory objects at boot, as a holder's creation makes them, and hands
 * their handles as -erx_record given (erx_boot_given_words), so a device that does DMA has one
 * form in every domain. The host link's UART and the line's, which do no DMA, are the
 * physical records, -erx_record device ROLE PERIPHERAL PATH BASE SIZE LINE MARK CLOCK INDEX OFF ON
 * (erx_boot_device_words), INDEX the device's row in the manifest's device table and OFF and ON its
 * power line's off and on times in milliseconds, 0 and 0 for a device with none
 * (docs/design-bluetooth.md, "The power line").
 * role and peripheral point at a row's names, PATH is the device's device-tree path, which
 * names it to its driver, and the numbers are the manifest's device entry.
 * MARK, in every form, is shared when another device of the unit names the line and direct
 * otherwise (docs/design-shared-devices.md, "Lines inside a domain"), so no driver decides
 * whether its line is shared. A manifest whose units hold no such device has no record: a
 * missing disk is a normal state. The host link's UART gives a record only when the boot asks for the host link,
 * with erx.hostlink=1 on the kernel command line.
 */
#define ERX_BOOT_DEVICES_MAX	8

typedef struct erx_boot_device {
	const char	*role;		/* the record's role word: "block", "net", "hostlink" or "line" */
	const char	*peripheral;	/* the peripheral's name in the CMSIS-SVD source */
	bool		given;		/* a row of erx/device_kinds.h; false for the host link's and the line's UARTs */
	/* A framebuffer row: no kind, role and peripheral NULL, given false; its record is the
	 * framebuffer record of its catalogue entry's facts (erx_boot_framebuffer_words). */
	bool		framebuffer;
	uint64_t	base;		/* the register window */
	uint64_t	size;
	uint32_t	line;		/* the interrupt, as the platform's controller numbers it */
	bool		line_shared;	/* another device of its unit names line (docs/design-shared-devices.md) */
	uint32_t	clock;		/* the device's clock in hertz; 0 for a device whose driver reads none */
	uint64_t	dma_memory;	/* a given device's memory for the boot, whole pages; 0 for none */
	bool		network;	/* a row of the network role, whose record carries the tree's MAC */
	erx_boot_words_t path;		/* its device-tree path, into the manifest's bytes */
	uint32_t	index;		/* its manifest device row, which is its catalogue entry's index */
	uint16_t	power_off_ms;	/* its power line's off time, from its manifest row; 0 for none */
	uint16_t	power_on_ms;	/* and its on time */
} erx_boot_device_t;

/*
 * The pages that hold a device's registers, which its window object covers, and where the
 * registers start in them: the OFFSET of its -erx_record given record.
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
 * A device the root reads itself at boot, with no driver and no record: a device-tree row
 * of a unit the system domain holds, its path into the manifest's bytes and its register
 * window as the platform record states it, which the firmware's tree only confirms
 * (erx_dt_registers). The Raspberry Pi 4's RNG200, firmware mailbox, watchdog and pin
 * controller are such devices (docs/design-fiasco.md, "The Raspberry Pi 4"). device is the
 * row's index in the manifest's devices table, which a pins row's device column names.
 */
typedef struct erx_boot_row {
	erx_boot_words_t	path;
	erx_dt_window_t		window;
	uint32_t		device;
} erx_boot_row_t;

/*
 * Fills *row from the first device-tree row of a unit the system domain holds whose
 * compatible string is compatible; false, writing nothing, when the manifest has none, so
 * a manifest that does not give the system domain the device keeps the root off it.
 */
bool	erx_boot_held_row(const erx_manifest_view_t *view, const char *compatible, erx_boot_row_t *row);

/*
 * The pins rows the root writes once at boot (docs/design-pinctrl.md, "What the code does
 * today"): each row whose device column is device, the row of the pin controller the
 * system domain holds (erx_boot_held_row), of a pin first or above, that sets a device's
 * pin to a signal in its default state. A row of another controller is its holder's to
 * apply, a pin below first is config.txt's, and a device's other states and plain GPIO
 * pins are the pin driver's. Copies them into rows in table order and sets *count; false,
 * with *count 0, when a row cannot be read or more than max are taken, so the plan is
 * taken whole or not at all.
 */
bool	erx_boot_pin_rows(const erx_manifest_view_t *view, uint32_t device, uint32_t first, erx_mf_pin_t *rows,
	    size_t max, size_t *count);

/*
 * Whether the manifest's console is the UART /chosen/stdout-path names
 * (docs/design-system.md, "Devices"): stdout_path is that node's full path, as
 * bootstrap resolved it, and the two paths match whole. An empty stdout_path, a
 * tree that names no node, matches no console.
 */
bool	erx_boot_console_matches(const erx_boot_manifest_t *manifest, const char *stdout_path,
	    size_t stdout_len);

/*
 * Writes a physical record's words, -erx_record device ROLE PERIPHERAL PATH BASE SIZE LINE MARK CLOCK INDEX
 * with the numbers in decimal and MARK direct or shared by line_shared, each word ended by
 * NUL, into words, and returns their whole length. Returns 0, having written nothing past
 * capacity, when they do not fit, for a path erx_boot_device_path_valid refuses, or for a
 * framebuffer row, which has no role or peripheral.
 * Only a device that is not given has this record; a given one's is -erx_record given
 * (erx_boot_device_given), and a framebuffer's the framebuffer record
 * (erx_boot_framebuffer_words).
 */
size_t	erx_boot_device_words(const erx_boot_device_t *device, char *words, size_t capacity);

/*
 * Writes the console's words, -erx_record console PERIPHERAL BASE SIZE LINE MARK CLOCK, whose
 * console and PERIPHERAL are its kind's role word and peripheral, as
 * erx_boot_device_words writes a physical record's, into words, and returns their whole
 * length; 0, having written nothing past capacity, when they do not fit, which
 * ERX_BOOT_CONSOLE_WORDS_MAX bytes (erx/boot_words.h) always do, or when the console
 * has no kind.
 */
size_t	erx_boot_console_words(const erx_boot_console_t *console, char *words, size_t capacity);

/*
 * The pages of the device's registers into *window; false, writing nothing, for registers
 * that are empty or end past the top of the address space.
 */
bool	erx_boot_device_window(const erx_boot_device_t *device, erx_boot_window_t *window);

/*
 * A device given to a holder domain, as its creation installed it (docs/design-fiasco.md,
 * "Boot information"): the values of its objects in the holder's table, which the holder's
 * device NIF opens it by. window and line are its register window's and its line's IRQ
 * object's; offset and size place its registers in the window; memory is its contiguous
 * memory's, ERX_CAP_NULL with memory_size 0 for none; clock is the device's clock in hertz,
 * 0 for a device whose driver reads none; index is its manifest device row, by which the
 * PCIe domain matches a host bridge's record to its catalogue entry (erx_pcie_bridge.index).
 */
typedef struct erx_boot_given {
	const char	*role;		/* erx/device_kinds.h's role word */
	const char	*peripheral;	/* and its CMSIS-SVD peripheral */
	erx_boot_words_t path;		/* its device-tree path, its name (erx_boot_device_path_valid) */
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
	uint64_t	index;		/* its manifest device row */
} erx_boot_given_t;

/*
 * A PCIe function given to a holder domain (docs/design-pcie.md, "The catalogue and
 * gives"): its kind's names, its bridge's manifest device row and its place, its line's
 * IRQ object, wired or an MSI's, its memory as erx_boot_given_t's, its interrupt route
 * (ERX_PCIE_ROUTE_*), and for an MSI-X route the message its object's creation returned
 * and its table's BAR, offset and entries, zero for every other route; and each BAR, in
 * register order, by the window over its span and its offset there, ERX_CAP_NULL and 0
 * for a BAR not placed, and its hardware size as a power of two.
 */
typedef struct erx_boot_function {
	const char	*role;
	const char	*peripheral;
	uint64_t	bridge;
	uint8_t		bus, device, function;
	uint64_t	line;
	bool		line_shared;
	uint64_t	memory;
	uint64_t	memory_size;
	bool		coherent;
	uint8_t		route;
	erx_msi_message_t message;
	uint8_t		table_bar;
	uint32_t	table_offset;
	uint16_t	table_size;
	struct {
		uint64_t	window;
		uint64_t	offset;
		uint8_t		size_log2;
	} bars[sizeof(((erx_pcie_function_t *)NULL)->bars) / sizeof(erx_pcie_bar_t)];
} erx_boot_function_t;

/*
 * The given record of a device the root gives itself (docs/design-fiasco.md, "Device
 * records"): the device's names and register size, the offset of its window (from
 * erx_boot_device_window), and the handles of the objects the root made for it, its
 * register window, its line's IRQ object and its contiguous memory. A device without
 * dma_memory, or whose memory_handle is ERX_CAP_NULL because erx_boot_dma_absent refused
 * it memory, has none: the record names ERX_CAP_NULL with MEM_SIZE 0. facts are the
 * firmware tree's for a row that asked (erx_boot_row_asks), or NULL for a row that
 * asked nothing. COHERENT is erx_boot_coherent's; MAC is the facts' address for a network
 * row, and 0 otherwise.
 */
erx_boot_given_t	erx_boot_device_given(const erx_boot_device_t *device, const erx_boot_window_t *window,
	    const erx_dt_device_t *facts, uint64_t window_handle, uint64_t line_handle, uint64_t memory_handle);

/*
 * Writes -erx_record given ROLE PERIPHERAL PATH WINDOW_H OFFSET SIZE LINE_H MARK MEM_H MEM_SIZE CLOCK
 * COHERENT MAC INDEX, the numbers in decimal, COHERENT 1 or 0, MARK direct or shared by line_shared,
 * and each word ended by NUL, into words, and returns their whole length; 0, having written
 * nothing past capacity, for a path erx_boot_device_path_valid refuses or when they do not
 * fit, which ERX_BOOT_GIVEN_WORDS_MAX bytes (erx/boot_words.h) always do for names within
 * ERX_BOOT_NAME_WORD_MAX.
 */
size_t	erx_boot_given_words(const erx_boot_given_t *given, char *words, size_t capacity);

/* The -erx_record function words of a given PCIe function, as erx_boot_given_words writes a given device's. */
size_t	erx_boot_function_words(const erx_boot_function_t *function, char *words, size_t capacity);

/*
 * Whether path may be the PATH word of a device record: a device-tree node path
 * (erx_boot_node_path_valid) that is not empty and is at most ERX_DEVICE_PATH_MAX bytes,
 * the bound the manifest grammar holds devices[].path to (abi/manifest.txt), so its word
 * with its NUL fits ERX_BOOT_PATH_WORD_MAX.
 * The record writers write no other path, and the domain library's view admits no driven
 * device with another, so no creation fails for its device's name.
 */
bool	erx_boot_device_path_valid(erx_boot_words_t path);

/*
 * Whether the root asks the firmware's tree for a driven device row's facts
 * (docs/design-device-tree.md, "What each row asks"), by the row's DMA memory and whether
 * it is of the network role: a row with DMA memory asks for its coherence and DMA range, a
 * network row for its hardware address, and every other row nothing. The records read only
 * what the row asked from the facts.
 */
bool	erx_boot_row_asks(uint64_t dma_memory, bool network);

/*
 * The DMA memory a row's device gets before any is made (docs/design-device-tree.md, "Facts
 * into records"): the row's dma_memory when facts, the tree's for a row that asked, give a
 * range it may lie in (erx_boot_dma_absent with size 0), and 0 otherwise or for NULL facts,
 * a row that asked nothing. The root stores it in the row's catalogue entry, so the root's
 * own give and every holder's give make memory from the one decision.
 */
uint64_t	erx_boot_dma_memory(const erx_dt_device_t *facts, uint64_t dma_memory);

/*
 * The DMA translation a device's contiguous memory is made inside
 * (erx_mem_create_contiguous_in), from the facts of its catalogue entry: CPU addresses cpu
 * through last, which the device sees from bus. The one place a range is built from facts,
 * so no give hands a device with a bus offset its CPU addresses. It means something only
 * for facts that admit memory (erx_boot_dma_memory), the only ones a give makes memory for.
 */
erx_mem_dma_range_t	erx_boot_dma_range(const erx_dt_device_t *facts);

/*
 * A given record's COHERENT: the facts' coherence for a row that gets DMA memory
 * (erx_boot_dma_memory), and false for any other, so no record says coherent of a device
 * that has no range to use.
 */
bool	erx_boot_coherent(const erx_dt_device_t *facts, uint64_t dma_memory);

/*
 * The longest line erx_boot_tree_line writes: its fixed words, a node path of fewer than
 * ERX_PATH_MAX bytes, three addresses of 0x and 16 digits, and the newline; for "dma absent
 * ranges" also the limit, the count and ERX_BOOT_TREE_WINDOWS_SHOWN windows.
 */
#define ERX_BOOT_TREE_WINDOWS_SHOWN	4u
#define ERX_BOOT_TREE_LINE_MAX	(sizeof("erx: device tree: ") + ERX_PATH_MAX + \
	sizeof(": coherent 1 range ") + 3u * sizeof("0x0123456789abcdef") + sizeof(" mac present\n") + \
	sizeof(" limit 0x0123456789abcdef windows 4294967295 more 4294967295") + \
	ERX_BOOT_TREE_WINDOWS_SHOWN * (sizeof(" window ") + 3u * sizeof("0x0123456789abcdef ") + sizeof(" above_limit")))

/*
 * Writes the root's console line for a device row that asked the tree (erx_boot_row_asks;
 * docs/design-device-tree.md, "The lines"), at path, with dma_memory the row's and network
 * whether it is of the network role, without a NUL, into line, and returns its
 * length: "erx: device tree: PATH:", then for a row with DMA memory " coherent C range CPU
 * BUS LAST" or " dma absent REASON" (for "ranges" followed by the DMA walk's windows,
 * docs/design-device-tree.md, "The lines"), REASON being absent, the reason erx_boot_dma_absent gave
 * once the memory was made, or when absent is NULL the facts' own (erx_boot_dma_absent with
 * size 0), then
 * for a network row " mac present" or " mac absent", and a newline. PATH is the manifest's;
 * the numbers are the facts', addresses in hexadecimal; the reasons are fixed words, so no
 * byte of the tree reaches the line. Returns 0, having written nothing past capacity, for a
 * path that is not a node path (erx_boot_node_path_valid) or a line that does not fit, which
 * ERX_BOOT_TREE_LINE_MAX bytes always do for a path within ERX_PATH_MAX.
 */
size_t	erx_boot_tree_line(erx_boot_words_t path, uint64_t dma_memory, bool network, const erx_dt_device_t *facts,
	    const char *absent, char *line, size_t capacity);

/*
 * Why a device the firmware's tree describes by facts gets no DMA memory at device address
 * first, size bytes, the address erx_mem_dma_addr gives, or NULL when it may have it
 * (docs/design-device-tree.md, "Facts into records"): the reader's reason when the facts
 * have no DMA range ("no_node", "coherence", "cells", "malformed", "ranges"), and "outside"
 * when the memory does not lie whole inside the range's bus addresses, bus through
 * bus + (last - cpu), or that end would pass 2^64 - 1. size 0 asks before the memory is
 * made, so only the facts are checked. Each reason is a fixed word the root may print.
 */
const char	*erx_boot_dma_absent(const erx_dt_device_t *facts, uint64_t first, uint64_t size);

/* The tree's hardware address as a 48-bit number, its first byte highest; 0 for none. */
uint64_t	erx_boot_mac_number(const erx_dt_device_t *facts);

/*
 * Whether the framebuffer of facts fb, whose format's name is format, is placed: the one
 * decision of whether a framebuffer row has pages, an object over them and a record
 * (docs/design-device-tree.md, "Facts into records"). It is placed when its status is
 * ERX_DT_FB_OK, so the reader found it inside its row's window and outside RAM, format is a
 * name erx_boot_framebuffer_words takes, the framebuffer is not empty and ends below the
 * top of the address space, and its whole pages lie inside window, the row's; then *pages
 * is those pages, which its window object covers, with its offset in the first page. The
 * window check repeats the reader's, so no answer of the reader reaches a page outside the
 * manifest's row. Otherwise false, writing nothing. Facts no reader wrote, all zero, read
 * as ERX_DT_FB_OK but have length 0, and their format is NULL, so they are never placed.
 */
bool	erx_boot_framebuffer_place(const erx_dt_framebuffer_t *fb, const char *format, erx_dt_window_t window,
	    erx_boot_window_t *pages);

/*
 * Writes -erx_record framebuffer WINDOW_H OFFSET SIZE WIDTH HEIGHT STRIDE FORMAT into words: window
 * the handle of the object over the framebuffer's pages in its holder's table, offset the
 * framebuffer's in its first page (erx_boot_framebuffer_place), SIZE the reg length and
 * FORMAT format, the name erx_dt_fb_format_name gives fb->format, which the caller looks up
 * since this core does not link the tree reader. Returns their whole length; 0, having
 * written nothing past capacity, for facts whose status is not ERX_DT_FB_OK, a format that is
 * NULL, empty or longer than ERX_BOOT_FORMAT_WORD_MAX bytes with its NUL, or words that do
 * not fit, which ERX_BOOT_FRAMEBUFFER_WORDS_MAX bytes (erx/boot_words.h) always do.
 */
size_t	erx_boot_framebuffer_words(const erx_dt_framebuffer_t *fb, const char *format, uint64_t window,
	    uint64_t offset, char *words, size_t capacity);

/*
 * Writes the root's console line for a framebuffer row at path (docs/design-device-tree.md,
 * "The lines"), without a NUL, into line, and returns its length: "erx: device tree: PATH:"
 * then " framebuffer WIDTHxHEIGHT STRIDE FORMAT", FORMAT format as for
 * erx_boot_framebuffer_words, " framebuffer absent outside BASE SIZE" with the reg range the
 * reader found outside the row's window or inside RAM, or " framebuffer absent REASON",
 * REASON one of "none", "ambiguous", "malformed" and "unsupported", then a newline.
 * Addresses are hexadecimal, other numbers decimal, the reasons and the format's name fixed
 * words, so no byte of the tree reaches the line. Returns 0, having written nothing past
 * capacity, for a path that is not a node path, facts of ERX_DT_FB_OK without a format
 * erx_boot_framebuffer_words takes, or a line that does not fit, which ERX_BOOT_TREE_LINE_MAX
 * bytes always do.
 */
size_t	erx_boot_framebuffer_line(erx_boot_words_t path, const erx_dt_framebuffer_t *fb, const char *format,
	    char *line, size_t capacity);

/*
 * Writes -erx_record boot VALUE SLOT by the names of include/erx/core/boot_pair.h into words, and
 * returns their whole length; 0 for a value or slot that has no name, or words that do not
 * fit, which ERX_BOOT_PAIR_WORDS_MAX bytes always do.
 */
size_t	erx_boot_pair_words(uint32_t value, uint32_t slot, char *words, size_t capacity);

/*
 * Writes -erx_record build ID, the boot image's build identifier in decimal, into words, and
 * returns their whole length; 0 for words that do not fit, which ERX_BOOT_BUILD_WORDS_MAX
 * bytes always do. The root writes it into the system domain's boot page and the domain library into
 * every other domain's, so each domain of the image names the same build.
 */
size_t	erx_boot_build_words(uint64_t build_id, char *words, size_t capacity);

/*
 * Writes -erx_record system_image LEN TREE_OFF TREE_LEN SALT ROOT [record_volume] from the
 * manifest's system_image row into words (docs/design-fiasco.md, "The booted slot"): the
 * image's length and the tree's offset and length in decimal, the salt's first salt_length
 * bytes and the root hash in lowercase hex, then, when record_volume is true, the ABI's
 * name of the record_volume window role, for a holder of that window too
 * (docs/design-storage.md, "Removable media: FAT"): the words erx_device_record:
 * system_image/1 and record_volume/1 read.
 * Returns their whole length; 0 for a salt_length out of 1 to the salt's array, or words
 * that do not fit, which ERX_BOOT_SYSTEM_IMAGE_WORDS_MAX bytes always do. The domain
 * library writes it into the boot page of the system window's holder alone.
 */
size_t	erx_boot_system_image_words(const erx_mf_system_image_t *row, bool record_volume, char *words,
	    size_t capacity);

/*
 * Writes -erx_record drive ROLE N into words (docs/design-fiasco.md, "Drive records"): ROLE
 * the name of role, ERX_MF_DEVICE_ROLE_USB or _BLOCK, the only two a drive window lies on,
 * and N number in decimal, the words erx_device_record:drives/2 reads. Returns their whole
 * length; 0 for another role, a number of ERX_MF_NONE, or words that do not fit, which
 * ERX_BOOT_DRIVE_WORDS_MAX bytes always do. The domain library writes one into a configured
 * domain's boot page per drive window on a device the domain holds.
 */
size_t	erx_boot_drive_words(uint32_t role, uint32_t number, char *words, size_t capacity);

#endif /* ERX_BACKEND_BOOT_MANIFEST_H */
