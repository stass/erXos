/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

#ifndef ERX_CORE_RNG200_H
#define ERX_CORE_RNG200_H

#include <stdint.h>

/*
 * The boot read of a board's RNG200 random generator (docs/design-platforms.md,
 * "Entropy sources"): 32 bytes, read when /chosen carries no seed, waiting at most
 * 100 ms. This is the pure part, which decides what the read does next from the FIFO
 * count and the clock; the caller's device shim reads the registers and nothing else.
 * The register facts are hw/svd/rng200/rng200.svd's.
 *
 * The shim starts a read with erx_rng200_start, then, until erx_rng200_next says DONE
 * or TIMED_OUT, reads FIFO_COUNT and the clock, passes both to erx_rng200_next, and on
 * TAKE reads FIFO_DATA *take times, handing each word to erx_rng200_take. A take never
 * asks for more words than the count said the FIFO holds, so no read meets an empty
 * FIFO, and the deadline is checked before each count, so the read ends within the
 * wait and the time of one pass.
 */

/* The device tree's compatible string of the generator. */
#define ERX_RNG200_COMPATIBLE	"brcm,bcm2711-rng200"
/* The bytes the boot read gives, and the 32-bit words that are. */
#define ERX_RNG200_SEED_BYTES	32
#define ERX_RNG200_WORDS	(ERX_RNG200_SEED_BYTES / 4)
/* The longest the boot read waits, in nanoseconds. */
#define ERX_RNG200_WAIT_NS	UINT64_C(100000000)

#ifdef __cplusplus
extern "C" {
#endif

typedef struct erx_rng200_read erx_rng200_read_t;

/*
 * A read in progress: the clock's value at which it gives up, and the words taken so
 * far, the first words entries of data. Invariant: words <= ERX_RNG200_WORDS. The
 * words are secret; whoever holds them erases them.
 */
struct erx_rng200_read {
	uint64_t	deadline_ns;
	uint32_t	words;
	uint32_t	data[ERX_RNG200_WORDS];
};

typedef enum erx_rng200_action {
	/* Read FIFO_COUNT again. */
	ERX_RNG200_POLL,
	/* Read FIFO_DATA *take times. */
	ERX_RNG200_TAKE,
	/* All ERX_RNG200_WORDS words are in. */
	ERX_RNG200_DONE,
	/* The wait is over with fewer words. */
	ERX_RNG200_TIMED_OUT
} erx_rng200_action_t;

/* A read that starts at now_ns. A deadline past the clock's end is its end. */
erx_rng200_read_t	erx_rng200_start(uint64_t now_ns);
/*
 * What the read does after FIFO_COUNT read count at now_ns. *take is the words to read
 * on ERX_RNG200_TAKE, at least one, and 0 otherwise.
 */
erx_rng200_action_t	erx_rng200_next(const erx_rng200_read_t *read, uint32_t count, uint64_t now_ns,
			    uint32_t *take);
/* Adds one word the FIFO gave. A word past ERX_RNG200_WORDS is dropped. */
void			erx_rng200_take(erx_rng200_read_t *read, uint32_t word);

#ifdef __cplusplus
}
#endif

#endif /* ERX_CORE_RNG200_H */
