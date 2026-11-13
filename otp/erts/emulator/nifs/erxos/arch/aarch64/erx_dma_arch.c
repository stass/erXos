/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

/*
 * The DMA architecture layer on AArch64, at EL0 (docs/design-arch-aarch64.md, "Cache
 * maintenance"): DC CVAC and DC CIVAC by address, DSB SY and DMB SY, and the two sizes from
 * CTR_EL0. EL0 may read CTR_EL0 and issue these instructions because the kernel sets
 * SCTLR_EL1.UCT and UCI.
 */

#include <stdbool.h>
#include <stdint.h>

#include "erx_dma_arch.h"

/*
 * CTR_EL0's two fields read here, each the log2 of a size in 4-byte words: DminLine, bits
 * [19:16], and CWG, bits [27:24] (Arm's machine-readable register data, release 2026-09,
 * Registers.json). They are written out here because hw/sysreg/aarch64.json cannot hold
 * CTR_EL0 yet and no generator makes C accessors from it (TODO.md, "CTR_EL0").
 */
#define CTR_DMINLINE_SHIFT	16u
#define CTR_CWG_SHIFT		24u
#define CTR_FIELD_MASK		UINT64_C(0xf)
#define CTR_WORD_BYTES		4u
/* The granule when CWG is 0, which says the CPU does not report one (design-device-dma.md, open decision 1). */
#define GRANULE_UNREPORTED	2048u

static uint64_t
cache_type(void)
{
	uint64_t type;

	__asm__ volatile("mrs %0, ctr_el0" : "=r"(type));
	return (type);
}

uint32_t
erx_dma_line(void)
{
	return (CTR_WORD_BYTES << ((cache_type() >> CTR_DMINLINE_SHIFT) & CTR_FIELD_MASK));
}

/* Never below the line, so the sequencer's L <= G holds whatever the CPU reports. */
uint32_t
erx_dma_granule(void)
{
	const uint64_t cwg = (cache_type() >> CTR_CWG_SHIFT) & CTR_FIELD_MASK;
	const uint32_t granule = cwg == 0 ? GRANULE_UNREPORTED : CTR_WORD_BYTES << cwg;
	const uint32_t line = erx_dma_line();

	return (granule < line ? line : granule);
}

void
erx_dma_clean(volatile uint8_t *start, uint64_t length, uint32_t step)
{
	for (uint64_t at = 0; at < length; at += step)
		__asm__ volatile("dc cvac, %0" :: "r"(start + at) : "memory");
}

void
erx_dma_clean_inval(volatile uint8_t *start, uint64_t length, uint32_t step)
{
	for (uint64_t at = 0; at < length; at += step)
		__asm__ volatile("dc civac, %0" :: "r"(start + at) : "memory");
}

void
erx_dma_publish_barrier(bool completes)
{
	if (completes)
		__asm__ volatile("dsb sy" ::: "memory");
	else
		__asm__ volatile("dmb sy" ::: "memory");
}

void
erx_dma_report_barrier(void)
{
	__asm__ volatile("dmb sy" ::: "memory");
}

void
erx_dma_completion_barrier(void)
{
	__asm__ volatile("dsb sy" ::: "memory");
}
