/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

/*
 * The device-tree reader (docs/design-device-tree.md, "The reader"). The
 * tree is untrusted input. erx_dt_accept hands the bytes to fdt_check_full
 * before anything else reads them, then walks the nodes once, refusing a
 * node deeper than ERX_DT_DEPTH_MAX and collecting the memory ranges. Every
 * later call takes the accepted view. Nothing here recurses or allocates:
 * walks keep the path from the root in a fixed array indexed by depth, and
 * the DMA walk carries at most ERX_DT_WINDOWS_MAX windows per level, so no
 * path is longer than the tree's length times those two bounds.
 *
 * libfdt is compiled with every check on (FDT_ASSUME_MASK 0), so no copy's
 * default decides which checks run; the guard below fails the build of a
 * reader compiled without it.
 */

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <string.h>

#include <libfdt.h>

#include "erx/abi.h"
#include "erx/core/dt.h"

#if !defined(FDT_ASSUME_MASK) || FDT_ASSUME_MASK != 0
#error "erx_dt needs libfdt compiled with -DFDT_ASSUME_MASK=0"
#endif

/* The longest node path a row may name. */
#define DT_PATH_MAX	1024
/* The bytes of one cell. */
#define DT_CELL		4

/*
 * A walk over the nodes in document order. path[d] is the offset of the
 * node at depth d on the way from the root to the current node, so
 * path[depth - 1] is the current node's parent.
 */
typedef struct dt_walk {
	int	 offset;
	int	 depth;
	int	 path[ERX_DT_DEPTH_MAX + 1];
} dt_walk_t;

/*
 * One DMA window: bus addresses bus through last of the device, which at
 * the walk's current level are the addresses from at on. Invariant:
 * at + (last - bus) does not overflow.
 */
typedef struct dt_window {
	uint64_t	 bus;
	uint64_t	 last;
	uint64_t	 at;
} dt_window_t;

/* The address at the current level of the window's last bus address. */
static uint64_t
window_at_last(const dt_window_t *window)
{
	return (window->at + (window->last - window->bus));
}

/* A framebuffer format of the simple-framebuffer binding. */
typedef struct dt_format {
	const char	*name;
	uint32_t	 bits;
} dt_format_t;

/*
 * The binding's eleven format names, in its order, with their bits per
 * pixel (Linux 6.18 Documentation/devicetree/bindings/display/
 * simple-framebuffer.yaml:97-119, read through a clean-room facts record).
 */
static const dt_format_t dt_formats[] = {
	{ "a1r5g5b5", 16 }, { "a2r10g10b10", 32 }, { "a8b8g8r8", 32 }, { "a8r8g8b8", 32 },
	{ "r5g6b5", 16 }, { "r5g5b5a1", 16 }, { "r8g8b8", 24 }, { "x1r5g5b5", 16 },
	{ "x2r10g10b10", 32 }, { "x8r8g8b8", 32 }, { "x8b8g8r8", 32 }
};
#define DT_FORMATS	(sizeof(dt_formats) / sizeof(dt_formats[0]))

static void
walk_start(dt_walk_t *walk)
{
	walk->offset = 0;
	walk->depth = 0;
	walk->path[0] = 0;
}

/*
 * Moves to the next node. Returns false at the end of the tree, on a
 * libfdt error (walk->offset negative) and on a node deeper than
 * ERX_DT_DEPTH_MAX (walk->depth above it), which is never stored.
 */
static bool
walk_next(const void *fdt, dt_walk_t *walk)
{
	walk->offset = fdt_next_node(fdt, walk->offset, &walk->depth);
	if (walk->offset < 0 || walk->depth < 0 || walk->depth > ERX_DT_DEPTH_MAX)
		return (false);
	walk->path[walk->depth] = walk->offset;
	return (true);
}

/* A big-endian number of count cells, count 1 or 2, at at. */
static uint64_t
cells_read(const uint8_t *at, int count)
{
	uint64_t value;
	int i;

	value = 0;
	for (i = 0; i < count * DT_CELL; i++)
		value = value << 8 | at[i];
	return (value);
}

static bool
cells_valid(int count)
{
	return (count == 1 || count == 2);
}

static bool
prop_present(const void *fdt, int node, const char *name)
{
	return (fdt_getprop(fdt, node, name, NULL) != NULL);
}

/* Whether a property's value is exactly the string text. */
static bool
prop_is(const void *fdt, int node, const char *name, const char *text)
{
	const char *value;
	size_t length;
	int len;

	value = fdt_getprop(fdt, node, name, &len);
	length = strlen(text);
	return (value != NULL && len >= 0 && (size_t)len == length + 1 && memcmp(value, text, length + 1) == 0);
}

/* Whether a node's status is absent or "okay". */
static bool
node_enabled(const void *fdt, int node)
{
	return (!prop_present(fdt, node, "status") || prop_is(fdt, node, "status", "okay"));
}

/* Whether [first, last] meets any memory range of the view. */
static bool
memory_meets(const erx_dt_t *tree, uint64_t first, uint64_t last)
{
	uint32_t i;

	for (i = 0; i < tree->memory_count; i++)
		if (tree->memory[i].first <= last && first <= tree->memory[i].last)
			return (true);
	return (false);
}

/*
 * Adds the ranges of a memory node's reg, read with its parent's cell
 * counts. An empty range adds nothing: the firmware fills a memory node
 * that a board's tree leaves as zeros.
 */
static bool
memory_add(const void *fdt, int node, int parent, erx_dt_t *tree)
{
	const uint8_t *reg;
	uint64_t base, size;
	int ac, sc, entry, len, at;

	ac = fdt_address_cells(fdt, parent);
	sc = fdt_size_cells(fdt, parent);
	if (!cells_valid(ac) || !cells_valid(sc))
		return (false);
	reg = fdt_getprop(fdt, node, "reg", &len);
	if (reg == NULL)
		return (len == -FDT_ERR_NOTFOUND);
	entry = (ac + sc) * DT_CELL;
	if (len % entry != 0)
		return (false);
	for (at = 0; at < len; at += entry) {
		base = cells_read(reg + at, ac);
		size = cells_read(reg + at + ac * DT_CELL, sc);
		if (size == 0)
			continue;
		if (tree->memory_count == ERX_DT_MEMORY_MAX ||
		    __builtin_add_overflow(base, size - 1, &tree->memory[tree->memory_count].last))
			return (false);
		tree->memory[tree->memory_count++].first = base;
	}
	return (true);
}

const char *
erx_dt_accept(const void *bytes, size_t size, erx_dt_t *tree)
{
	dt_walk_t walk;

	memset(tree, 0, sizeof(*tree));
	/*
	 * fdt_check_header reads the strings block's size, the field a
	 * version 3 header adds, whatever the header's version, so a buffer
	 * shorter than the latest header is refused before libfdt reads it.
	 */
	if (bytes == NULL || size < FDT_V17_SIZE || fdt_check_full(bytes, size) != 0)
		return ("structure");

	walk_start(&walk);
	do {
		if (walk.depth == 1 && prop_is(bytes, walk.offset, "device_type", "memory") &&
		    node_enabled(bytes, walk.offset) &&
		    !memory_add(bytes, walk.offset, walk.path[walk.depth - 1], tree)) {
			memset(tree, 0, sizeof(*tree));
			return ("memory");
		}
	} while (walk_next(bytes, &walk));
	if (walk.depth > ERX_DT_DEPTH_MAX || (walk.offset < 0 && walk.offset != -FDT_ERR_NOTFOUND)) {
		memset(tree, 0, sizeof(*tree));
		return (walk.depth > ERX_DT_DEPTH_MAX ? "depth" : "structure");
	}
	tree->bytes = bytes;
	tree->size = size;
	return (NULL);
}

/* The offset of the node at path, an absolute path no longer than DT_PATH_MAX, or -1. */
static int
node_find(const erx_dt_t *tree, const char *path)
{
	size_t length;
	int node;

	if (tree->bytes == NULL || path == NULL || path[0] != '/')
		return (-1);
	length = strnlen(path, DT_PATH_MAX + 1);
	if (length > DT_PATH_MAX)
		return (-1);
	node = fdt_path_offset_namelen(tree->bytes, path, (int)length);
	return (node < 0 ? -1 : node);
}

/*
 * Fills path[0..depth] with the nodes from the root to node and returns
 * node's depth, or -1 if the walk does not reach it.
 */
static int
ancestry(const void *fdt, int node, int path[ERX_DT_DEPTH_MAX + 1])
{
	dt_walk_t walk;

	walk_start(&walk);
	do {
		if (walk.offset == node) {
			memcpy(path, walk.path, sizeof(walk.path));
			return (walk.depth);
		}
	} while (walk_next(fdt, &walk));
	return (-1);
}

/*
 * The node's coherence. The node's own dma-coherent or dma-noncoherent
 * decides, and must be empty. Both on the node, or a mark above it that
 * the node does not carry itself, give ERX_DT_DMA_COHERENCE: there the
 * readings of a mark on a bus disagree, and the specification defines the
 * mark only on a device. A mark above that repeats the node's own changes
 * no reading, as QEMU virt's dma-coherent on the root repeats each
 * device's.
 */
static erx_dt_dma_status_t
coherence_read(const void *fdt, const int path[ERX_DT_DEPTH_MAX + 1], int depth, bool *coherent)
{
	const void *on, *off;
	int on_len, off_len, i;

	on = fdt_getprop(fdt, path[depth], "dma-coherent", &on_len);
	off = fdt_getprop(fdt, path[depth], "dma-noncoherent", &off_len);
	if (on != NULL && off != NULL)
		return (ERX_DT_DMA_COHERENCE);
	if ((on != NULL && on_len != 0) || (off != NULL && off_len != 0))
		return (ERX_DT_DMA_MALFORMED);
	for (i = 0; i < depth; i++)
		if ((on == NULL && prop_present(fdt, path[i], "dma-coherent")) ||
		    (off == NULL && prop_present(fdt, path[i], "dma-noncoherent")))
			return (ERX_DT_DMA_COHERENCE);
	*coherent = on != NULL;
	return (ERX_DT_DMA_OK);
}

/*
 * Translates the windows in through one non-empty dma-ranges, entries of
 * ac bus address cells, pac parent address cells and sc length cells, into
 * out. The parts of a window no entry covers drop out.
 */
static erx_dt_dma_status_t
windows_translate(const uint8_t *ranges, int len, int ac, int pac, int sc, const dt_window_t *in, uint32_t in_count,
    dt_window_t out[ERX_DT_WINDOWS_MAX], uint32_t *out_count)
{
	uint64_t child, parent, size, child_last, parent_last, window_last, low, high;
	uint32_t count, i;
	int entry, offset;

	entry = (ac + pac + sc) * DT_CELL;
	if (len % entry != 0)
		return (ERX_DT_DMA_MALFORMED);
	count = 0;
	for (offset = 0; offset < len; offset += entry) {
		child = cells_read(ranges + offset, ac);
		parent = cells_read(ranges + offset + ac * DT_CELL, pac);
		size = cells_read(ranges + offset + (ac + pac) * DT_CELL, sc);
		if (size == 0)
			continue;
		if (__builtin_add_overflow(child, size - 1, &child_last) ||
		    __builtin_add_overflow(parent, size - 1, &parent_last))
			return (ERX_DT_DMA_MALFORMED);
		for (i = 0; i < in_count; i++) {
			window_last = window_at_last(&in[i]);
			low = in[i].at > child ? in[i].at : child;
			high = window_last < child_last ? window_last : child_last;
			if (low > high)
				continue;
			if (count == ERX_DT_WINDOWS_MAX)
				return (ERX_DT_DMA_RANGES);
			out[count].bus = in[i].bus + (low - in[i].at);
			out[count].last = in[i].bus + (high - in[i].at);
			out[count].at = parent + (low - child);
			count++;
		}
	}
	*out_count = count;
	return (ERX_DT_DMA_OK);
}

/*
 * The walk of erx_dma_ranges (docs/design-kernel.md, "DMA and the IOMMU"),
 * from the bus at path[bus_level] up to the root, then the RAM filter. A level's
 * dma-ranges maps its own addresses, in its own #address-cells and
 * #size-cells, to its parent's, in the parent's #address-cells. A level
 * without the property passes the windows only while no level above it
 * has a non-empty one; the root, which has no parent to map into, passes
 * them only through no dma-ranges or an empty one. Each level translates
 * one of the two window arrays into the other.
 */
static erx_dt_dma_status_t
range_read(const erx_dt_t *tree, const int path[ERX_DT_DEPTH_MAX + 1], int bus_level, erx_dt_device_t *facts)
{
	dt_window_t windows[2][ERX_DT_WINDOWS_MAX];
	const dt_window_t *found;
	const uint8_t *ranges;
	erx_dt_dma_status_t status;
	uint32_t count, translated, kept, i;
	bool missing;
	int level, len, ac, sc, pac, side;

	windows[0][0] = (dt_window_t){ .bus = 0, .last = UINT64_MAX, .at = 0 };
	count = 1;
	side = 0;
	missing = false;
	for (level = bus_level; level >= 0; level--) {
		ranges = fdt_getprop(tree->bytes, path[level], "dma-ranges", &len);
		if (ranges == NULL) {
			if (len != -FDT_ERR_NOTFOUND)
				return (ERX_DT_DMA_MALFORMED);
			missing = true;
			continue;
		}
		if (len == 0)
			continue;
		if (missing || level == 0)
			return (ERX_DT_DMA_MALFORMED);
		ac = fdt_address_cells(tree->bytes, path[level]);
		sc = fdt_size_cells(tree->bytes, path[level]);
		pac = fdt_address_cells(tree->bytes, path[level - 1]);
		if (!cells_valid(ac) || !cells_valid(sc) || !cells_valid(pac))
			return (ERX_DT_DMA_CELLS);
		status = windows_translate(ranges, len, ac, pac, sc, windows[side], count, windows[!side], &translated);
		if (status != ERX_DT_DMA_OK)
			return (status);
		count = translated;
		side = !side;
	}

	found = NULL;
	kept = 0;
	for (i = 0; i < count; i++) {
		if (memory_meets(tree, windows[side][i].at, window_at_last(&windows[side][i]))) {
			found = &windows[side][i];
			kept++;
		}
	}
	if (kept != 1)
		return (ERX_DT_DMA_RANGES);
	facts->cpu = found->at;
	facts->bus = found->bus;
	facts->last = window_at_last(found);
	return (ERX_DT_DMA_OK);
}

/*
 * The first of mac-address, local-mac-address and address, in FreeBSD's
 * order, that holds six bytes, not all zero, with the group bit clear.
 */
static void
mac_read(const void *fdt, int node, erx_dt_device_t *facts)
{
	static const char *const names[] = { "mac-address", "local-mac-address", "address" };
	static const uint8_t zero[ERX_DT_MAC_BYTES];
	const uint8_t *value;
	size_t i;
	int len;

	for (i = 0; i < sizeof(names) / sizeof(names[0]); i++) {
		value = fdt_getprop(fdt, node, names[i], &len);
		if (value == NULL || len != ERX_DT_MAC_BYTES || memcmp(value, zero, sizeof(zero)) == 0 ||
		    (value[0] & 1) != 0)
			continue;
		memcpy(facts->mac, value, ERX_DT_MAC_BYTES);
		facts->mac_status = ERX_DT_MAC_OK;
		return;
	}
}

void
erx_dt_device(const erx_dt_t *tree, const char *path, erx_dt_row_t row, erx_dt_device_t *facts)
{
	int nodes[ERX_DT_DEPTH_MAX + 1];
	int node, depth, bus_level;

	memset(facts, 0, sizeof(*facts));
	facts->dma = ERX_DT_DMA_NO_NODE;
	facts->mac_status = ERX_DT_MAC_NONE;
	node = node_find(tree, path);
	if (node < 0)
		return;
	depth = ancestry(tree->bytes, node, nodes);
	if (depth < 0)
		return;
	mac_read(tree->bytes, node, facts);

	bus_level = row == ERX_DT_ROW_PCIE ? depth : depth - 1;
	if (bus_level < 0)
		facts->dma = ERX_DT_DMA_MALFORMED;
	else
		facts->dma = coherence_read(tree->bytes, nodes, depth, &facts->coherent);
	if (facts->dma == ERX_DT_DMA_OK)
		facts->dma = range_read(tree, nodes, bus_level, facts);
	if (facts->dma != ERX_DT_DMA_OK) {
		facts->coherent = false;
		facts->cpu = facts->bus = facts->last = 0;
	}
}

/* A property of one cell, nonzero. */
static bool
cell_read(const void *fdt, int node, const char *name, uint32_t *value)
{
	const uint8_t *cell;
	int len;

	cell = fdt_getprop(fdt, node, name, &len);
	if (cell == NULL || len != DT_CELL)
		return (false);
	*value = (uint32_t)cells_read(cell, 1);
	return (*value != 0);
}

/* The index of the node's format in dt_formats, or DT_FORMATS. */
static size_t
format_find(const void *fdt, int node)
{
	size_t i;

	for (i = 0; i < DT_FORMATS; i++)
		if (prop_is(fdt, node, "format", dt_formats[i].name))
			return (i);
	return (DT_FORMATS);
}

/*
 * Checks the one matching node, whose parent is parent, against the
 * binding and then against its authority: its pages must lie inside the
 * row's window and outside every memory range the tree reports.
 */
static erx_dt_fb_status_t
fb_read(const erx_dt_t *tree, int parent, int node, erx_dt_window_t window, erx_dt_framebuffer_t *fb)
{
	const void *fdt = tree->bytes;
	const uint8_t *reg;
	uint64_t base, length, last, first_page, last_page, window_last;
	uint32_t width, height, stride;
	size_t format;
	int ac, sc, len;

	if (prop_present(fdt, node, "memory-region"))
		return (ERX_DT_FB_UNSUPPORTED);
	ac = fdt_address_cells(fdt, parent);
	sc = fdt_size_cells(fdt, parent);
	if (!cells_valid(ac) || !cells_valid(sc))
		return (ERX_DT_FB_MALFORMED);
	reg = fdt_getprop(fdt, node, "reg", &len);
	if (reg == NULL || len != (ac + sc) * DT_CELL)
		return (ERX_DT_FB_MALFORMED);
	base = cells_read(reg, ac);
	length = cells_read(reg + ac * DT_CELL, sc);
	if (length == 0 || __builtin_add_overflow(base, length - 1, &last))
		return (ERX_DT_FB_MALFORMED);
	if (!cell_read(fdt, node, "width", &width) || !cell_read(fdt, node, "height", &height) ||
	    !cell_read(fdt, node, "stride", &stride) || (format = format_find(fdt, node)) == DT_FORMATS)
		return (ERX_DT_FB_MALFORMED);
	/* Each factor is below 2^32, so neither product overflows. */
	if ((uint64_t)width * (dt_formats[format].bits / 8) > stride || (uint64_t)stride * height > length)
		return (ERX_DT_FB_MALFORMED);

	fb->base = base;
	fb->length = length;
	first_page = base & ~(uint64_t)(ERX_PAGE_SIZE - 1);
	last_page = last | (ERX_PAGE_SIZE - 1);
	if (window.size == 0 || __builtin_add_overflow(window.base, window.size - 1, &window_last) ||
	    first_page < window.base || last_page > window_last || memory_meets(tree, first_page, last_page))
		return (ERX_DT_FB_OUTSIDE);
	fb->width = width;
	fb->height = height;
	fb->stride = stride;
	fb->format = (uint32_t)format;
	fb->bits_per_pixel = dt_formats[format].bits;
	return (ERX_DT_FB_OK);
}

void
erx_dt_framebuffer(const erx_dt_t *tree, const char *path, const char *compatible, erx_dt_window_t window,
    erx_dt_framebuffer_t *fb)
{
	erx_dt_fb_status_t status;
	int parent, node, match;

	memset(fb, 0, sizeof(*fb));
	fb->status = ERX_DT_FB_NONE;
	parent = node_find(tree, path);
	if (parent < 0 || compatible == NULL)
		return;
	match = -1;
	fdt_for_each_subnode(node, tree->bytes, parent) {
		if (!node_enabled(tree->bytes, node) || fdt_node_check_compatible(tree->bytes, node, compatible) != 0)
			continue;
		if (match >= 0) {
			fb->status = ERX_DT_FB_AMBIGUOUS;
			return;
		}
		match = node;
	}
	if (match < 0)
		return;
	status = fb_read(tree, parent, match, window, fb);
	if (status != ERX_DT_FB_OK && status != ERX_DT_FB_OUTSIDE)
		memset(fb, 0, sizeof(*fb));
	fb->status = status;
}

const char *
erx_dt_fb_format_name(uint32_t format)
{
	return (format < DT_FORMATS ? dt_formats[format].name : NULL);
}
