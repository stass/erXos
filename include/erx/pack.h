/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

#ifndef ERX_PACK_H
#define ERX_PACK_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#include "erx/abi.h"

/*
 * The boot image's three pure checks (design-kernel.md, The boot image,
 * Checking a file and The bootable file):
 *
 * erx_boot_locate decides where the archive lies, from the first stage's
 *     locator and the memory the loader describes;
 * erx_pack_open checks the archive's index run, its hash first, and reads
 *     no file data;
 * erx_pack_file_check checks one file's run, its hash, its padding and the
 *     manifest an executable image or the system configuration carries,
 *     over a view erx_pack_open accepted.
 *
 * Each reads only the bytes it is given and returns a verdict; none
 * allocates or keeps state between calls. A refused erx_pack_open leaves
 * its view zero, and a refused erx_boot_locate leaves its range untouched.
 */

/* The reason of a refused version, whose error names the version found. */
#define ERX_PACK_REASON_VERSION "version"

typedef struct erx_blake3_ctx erx_blake3_ctx_t;
typedef struct erx_boot_inputs erx_boot_inputs_t;
typedef struct erx_boot_range erx_boot_range_t;
typedef struct erx_pack_error erx_pack_error_t;
typedef struct erx_pack_scratch erx_pack_scratch_t;
typedef struct erx_pack_view erx_pack_view_t;

/*
 * A refusal: the check that failed, the entry it concerns (UINT32_MAX for
 * the header and the locator), and for the version check the version found.
 */
struct erx_pack_error {
	const char	*reason;
	uint32_t	 entry;
	uint64_t	 found;
};

/* Caller-owned workspace; no input-sized array lives on a kernel stack. */
struct erx_pack_scratch {
	uint32_t	pending[ERX_PACK_PATH_MAX];
};

/* Successful views borrow bytes kept immutable for the view's lifetime. */
struct erx_pack_view {
	const uint8_t	*bytes;
	size_t		 length;
	erx_pack_header_t header;
};

/* A physical range [start, start + size). */
struct erx_boot_range {
	uint64_t	start;
	uint64_t	size;
};

/*
 * What the first stage knows at entry, read once by its caller: its locator
 * and where it runs, from its own image; the rest from the device tree.
 * memory and reserved are borrowed for the call.
 */
struct erx_boot_inputs {
	const uint8_t	*locator;	/* ERX_BOOT_LOCATOR_SIZE bytes */
	uint64_t	 load;		/* physical address of the first byte */
	uint64_t	 linked_end;	/* linked size, zero-initialised data included */
	uint64_t	 declared_size;	/* the size the boot header declares */
	bool		 has_initrd;
	erx_boot_range_t initrd;	/* /chosen's initrd range */
	erx_boot_range_t device_tree;
	const erx_boot_range_t *memory;
	size_t		 nmemory;
	const erx_boot_range_t *reserved;
	size_t		 nreserved;
};

bool erx_boot_locate(const erx_boot_inputs_t *, erx_boot_range_t *,
    erx_pack_error_t *);
bool erx_pack_open(const uint8_t *, size_t, erx_pack_scratch_t *,
    erx_blake3_ctx_t *, erx_pack_view_t *, erx_pack_error_t *);
bool erx_pack_file_check(const erx_pack_view_t *, uint32_t,
    erx_blake3_ctx_t *, erx_pack_error_t *);
bool erx_pack_entry_at(const erx_pack_view_t *, uint32_t,
    erx_pack_entry_t *);
bool erx_pack_path_at(const erx_pack_view_t *, uint32_t,
    const uint8_t **, size_t *);

#endif /* ERX_PACK_H */
