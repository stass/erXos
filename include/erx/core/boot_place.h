/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

#ifndef ERX_CORE_BOOT_PLACE_H
#define ERX_CORE_BOOT_PLACE_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#include "erx/core/boot_handoff.h"
#include "erx/core/boot_pair.h"
#include "erx/core/boot_range.h"

/*
 * What bootstrap decides before it changes anything (docs/design-stopgap.md,
 * "Boot handoff"). erx_boot_load_plan finds the archive, validates its index,
 * checks and plans each executable bootstrap places, chooses where they go,
 * and where the device tree's copy and the handoff page go, and returns the
 * whole plan; a refusal has changed nothing. It reads the
 * image only through the window the caller names and writes only the caller's
 * workspace and result, so the same function runs in bootstrap over physical
 * memory and on the host over a buffer.
 *
 * Bootstrap then applies the plan: it reserves the ranges, checks the kernel's
 * two views in the archive where the loader left it, writes the device tree's
 * copy and the record, and only then moves the archive when the plan moves it
 * and runs the copies, so every refusal comes before any of the archive's or
 * an image's bytes move.
 */

#ifdef __cplusplus
extern "C" {
#endif

#define ERX_BOOT_PLACE_COPIES_MAX	48
#define ERX_BOOT_WORKSPACE_SIZE		32768
#define ERX_BOOT_ID_SIZE		8
#define ERX_BOOT_HASH_SIZE		32
/* The image format's version, and the most of a command line the record holds. */
#define ERX_BOOT_IMAGE_VERSION		2
#define ERX_BOOT_ARGS_MAX		2048
/* The longest node path of /chosen/stdout-path the record holds. */
#define ERX_BOOT_STDOUT_MAX		256
/* The entry a refusal concerns when it concerns no entry. */
#define ERX_BOOT_NO_ENTRY		UINT32_MAX

typedef struct erx_boot_copy erx_boot_copy_t;
typedef struct erx_boot_error erx_boot_error_t;
typedef struct erx_boot_load_plan erx_boot_load_plan_t;
typedef struct erx_boot_load_request erx_boot_load_request_t;
typedef struct erx_boot_placed erx_boot_placed_t;
typedef struct erx_boot_workspace erx_boot_workspace_t;

/* The validator's scratch and hasher, which no stack holds. */
struct erx_boot_workspace {
	uint64_t	bytes[ERX_BOOT_WORKSPACE_SIZE / sizeof(uint64_t)];
};

struct erx_boot_load_request {
	const uint8_t	*locator;	/* the first stage's own locator */
	uint64_t	 load;		/* physical address of its first byte */
	uint64_t	 linked_end;	/* its linked size */
	uint64_t	 declared_size;	/* the size its boot header declares */
	bool		 has_initrd;
	erx_boot_range_t initrd;
	erx_boot_range_t device_tree;
	const erx_boot_range_t *memory;
	size_t		 nmemory;
	const erx_boot_range_t *reserved;
	size_t		 nreserved;
	uint64_t	 koptions_min;	/* the kernel's options record's size */
	/* Where physical address window_start can be read. */
	const uint8_t	*window;
	uint64_t	 window_start;
	uint64_t	 window_size;
};

/*
 * A refusal: the check that failed. path is one of the constant role paths when
 * the check concerns a role, or "device tree" or "handoff page" when it concerns
 * that place; entry is the index when it concerns an entry; the archive's own
 * bytes are never quoted, so a diagnostic needs no escaping.
 */
struct erx_boot_error {
	const char	*reason;
	const char	*path;
	uint32_t	 entry;
	uint64_t	 found;
	uint64_t	 offset;
};

/* One copy: file_size bytes from source, zeros up to mem_size. */
struct erx_boot_copy {
	uint64_t	source;
	uint64_t	target;
	uint64_t	file_size;
	uint64_t	mem_size;
};

/* An image's whole extent, page-rounded, and where it starts running. */
struct erx_boot_placed {
	uint64_t	start;
	uint64_t	size;
	uint64_t	entry;
};

/*
 * archive is where the archive lies once the plan is applied: every copy's
 * source, the reservation and the record name it. archive_loaded is where the
 * loader left it, the same range unless an image that runs at its link
 * addresses lands on it (docs/design-stopgap.md, "Boot handoff"); bootstrap
 * then moves the archive's bytes from archive_loaded.start to archive.start,
 * as memmove does, since the two may overlap, before any copy.
 *
 * kip_loaded and koptions_loaded are where the kernel's two views lie before
 * anything moves, in the archive at archive_loaded, so their contents can be
 * checked before the plan is applied. tree_copy is the room for the device
 * tree's copy, the tree's declared size in whole pages, and handoff_page the
 * handoff page's address; both are clear of every other place, the loaded
 * archive's included, so bootstrap writes them before it moves anything.
 */
struct erx_boot_load_plan {
	erx_boot_range_t archive;
	erx_boot_range_t archive_loaded;
	uint32_t	 flags;
	uint32_t	 root_entry;
	uint8_t		 build_id[ERX_BOOT_ID_SIZE];
	uint8_t		 index_hash[ERX_BOOT_HASH_SIZE];
	erx_boot_placed_t kernel;
	erx_boot_placed_t sigma0;
	bool		 has_stand_in_root;
	erx_boot_placed_t stand_in_root;
	erx_boot_range_t kip;		/* placed, inside the kernel */
	erx_boot_range_t koptions;	/* placed, inside the kernel */
	uint64_t	 kip_loaded;
	uint64_t	 koptions_loaded;
	erx_boot_range_t tree_copy;
	uint64_t	 handoff_page;
	uint32_t	 ncopies;
	erx_boot_copy_t	 copies[ERX_BOOT_PLACE_COPIES_MAX];
};

bool erx_boot_load_plan(const erx_boot_load_request_t *, erx_boot_workspace_t *,
    erx_boot_load_plan_t *, erx_boot_error_t *);

/* The length of a command line cut at the last whole word within limit. */
size_t erx_boot_args_cut(const char *, size_t, size_t);

/*
 * The boot value and its slot from the raw bytes of /chosen/bootloader's
 * partition and tryboot properties, each NULL when absent
 * (docs/design-platforms.md, "What the loader hands over"). Each is one
 * big-endian 32-bit cell: the partition booted, its index in the master boot
 * record counted from 1, and 1 for a trial or 0 for any other boot. A missing
 * property, a property of another length, a tryboot other than 0 or 1, or a
 * partition that is not a slot of abi/medium.txt gives unknown with slot
 * none. The bytes may lie at any alignment.
 */
erx_boot_pair_t erx_boot_pair_derive(const void *, size_t, const void *, size_t);

/*
 * Writes the handoff record over size bytes at record from the plan, the
 * first bootargs_len bytes of bootargs, at most the record's bound, the
 * stdout_len bytes of the node path /chosen/stdout-path names, at most
 * ERX_BOOT_STDOUT_MAX, stored empty unless it is a node path
 * (erx_boot_node_path_valid), the boot pair and the range of the device
 * tree's copy, and the boot CPU's identification words (erx_boot_cpu_id_read). Returns false when the record does not fit, the pair is one a reader refuses
 * (erx_boot_pair_valid) or the tree's range is (erx_boot_tree_range_valid),
 * and then writes nothing.
 */
bool erx_boot_handoff_write(const erx_boot_load_plan_t *, const char *, size_t,
    const char *, size_t, erx_boot_pair_t, erx_boot_range_t,
    const uint64_t [ERX_BOOT_CPU_ID_COUNT], uint8_t *, size_t);

#ifdef __cplusplus
}
#endif

#endif /* ERX_CORE_BOOT_PLACE_H */
