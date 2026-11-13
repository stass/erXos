/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

#ifndef ERX_CORE_DT_H
#define ERX_CORE_DT_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

/*
 * The device-tree reader (docs/design-device-tree.md, "The reader"): a pure
 * function over a flattened device tree the firmware wrote, which is
 * untrusted input. erx_dt_accept checks the bytes whole and gives a view;
 * every later call takes the view, so no call reads a tree that was not
 * accepted. Every answer is a value, never a pointer into the tree.
 */

#ifdef __cplusplus
extern "C" {
#endif

/* The deepest node accepted, the root being level 0. */
#define ERX_DT_DEPTH_MAX	16
/* The most memory ranges the memory nodes may give. */
#define ERX_DT_MEMORY_MAX	16
/* The most DMA windows a walk carries at one level. */
#define ERX_DT_WINDOWS_MAX	16
/* The bytes of a hardware (MAC) address. */
#define ERX_DT_MAC_BYTES	6

typedef struct erx_dt_memory erx_dt_memory_t;
typedef struct erx_dt erx_dt_t;
typedef struct erx_dt_device erx_dt_device_t;
typedef struct erx_dt_window erx_dt_window_t;
typedef struct erx_dt_framebuffer erx_dt_framebuffer_t;

/* One range of RAM: first and last address, so no range overflows. */
struct erx_dt_memory {
	uint64_t	 first;
	uint64_t	 last;
};

/* An accepted tree: its bytes and the RAM its memory nodes report. Only
 * erx_dt_accept fills it; every other call trusts it. */
struct erx_dt {
	const void	*bytes;
	size_t		 size;
	uint32_t	 memory_count;
	erx_dt_memory_t	 memory[ERX_DT_MEMORY_MAX];
};

/* What a manifest row's path names. */
typedef enum erx_dt_row {
	/* A device's own node; its bus is the node's parent. */
	ERX_DT_ROW_NODE,
	/* A PCIe host bridge, standing for its function: it is node and bus. */
	ERX_DT_ROW_PCIE
} erx_dt_row_t;

typedef enum erx_dt_dma_status {
	ERX_DT_DMA_OK,
	ERX_DT_DMA_NO_NODE,
	ERX_DT_DMA_COHERENCE,
	ERX_DT_DMA_CELLS,
	ERX_DT_DMA_MALFORMED,
	ERX_DT_DMA_RANGES
} erx_dt_dma_status_t;

typedef enum erx_dt_mac_status {
	ERX_DT_MAC_OK,
	ERX_DT_MAC_NONE
} erx_dt_mac_status_t;

/*
 * A device's facts. coherent, cpu, bus and last mean something only when
 * dma is ERX_DT_DMA_OK, so a device never has a range without its
 * coherence; mac only when mac_status is ERX_DT_MAC_OK. The range is the
 * device's translation: the device sees CPU address cpu + x at bus address
 * bus + x, for every CPU address from cpu through last, inclusive.
 */
struct erx_dt_device {
	erx_dt_dma_status_t	 dma;
	bool			 coherent;
	uint64_t		 cpu;
	uint64_t		 bus;
	uint64_t		 last;
	erx_dt_mac_status_t	 mac_status;
	uint8_t			 mac[ERX_DT_MAC_BYTES];
};

/* A manifest row's window: the range of CPU addresses it admits. */
struct erx_dt_window {
	uint64_t	 base;
	uint64_t	 size;
};

typedef enum erx_dt_fb_status {
	ERX_DT_FB_OK,
	ERX_DT_FB_NONE,
	ERX_DT_FB_AMBIGUOUS,
	ERX_DT_FB_MALFORMED,
	ERX_DT_FB_UNSUPPORTED,
	ERX_DT_FB_OUTSIDE
} erx_dt_fb_status_t;

/*
 * A framebuffer's facts. base and length mean something on ERX_DT_FB_OK
 * and ERX_DT_FB_OUTSIDE, the rest on ERX_DT_FB_OK only. format indexes
 * the reader's table of the binding's names (erx_dt_fb_format_name).
 */
struct erx_dt_framebuffer {
	erx_dt_fb_status_t	 status;
	uint64_t		 base;
	uint64_t		 length;
	uint32_t		 width;
	uint32_t		 height;
	uint32_t		 stride;
	uint32_t		 format;
	uint32_t		 bits_per_pixel;
};

/*
 * Accepts size bytes at bytes as a tree, filling *tree. Returns NULL, or
 * the fixed reason "structure", "depth" or "memory".
 */
const char	*erx_dt_accept(const void *bytes, size_t size, erx_dt_t *tree);

/* Fills *facts with the coherence, DMA range and hardware address of the
 * device at path, an absolute node path. */
void		 erx_dt_device(const erx_dt_t *tree, const char *path, erx_dt_row_t row, erx_dt_device_t *facts);

/* Fills *fb from the one enabled child of path whose compatible list holds
 * compatible, checked against window and the tree's RAM. */
void		 erx_dt_framebuffer(const erx_dt_t *tree, const char *path, const char *compatible,
		    erx_dt_window_t window, erx_dt_framebuffer_t *fb);

/* The name of a framebuffer format index, or NULL past the table. */
const char	*erx_dt_fb_format_name(uint32_t format);

#ifdef __cplusplus
}
#endif

#endif /* ERX_CORE_DT_H */
