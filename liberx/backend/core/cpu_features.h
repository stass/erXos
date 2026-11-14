/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

#ifndef LIBERX_BACKEND_CORE_CPU_FEATURES_H
#define LIBERX_BACKEND_CORE_CPU_FEATURES_H

#include <stdint.h>

#include "erx/core/boot_handoff.h"

/*
 * The CPU feature words of the boot information page, in the encoding of the
 * C library's AT_HWCAP and AT_HWCAP2 (docs/design-runtime.md, "Boot
 * information"): a bit is set only for a feature the CPU has and the kernel
 * enables and saves for user mode.
 */
typedef struct erx_cpu_features {
	uint64_t	hwcap;
	uint64_t	hwcap2;
} erx_cpu_features_t;

/*
 * The feature words the boot CPU's identification words (the handoff's
 * cpu_id) give, a pure function of them that the architecture's layer
 * defines (liberx/backend/core/arch/<arch>/cpu_features.c). Words that claim
 * a feature the kernel does not enable and save give no bit for it.
 */
erx_cpu_features_t	erx_cpu_features(const uint64_t id[ERX_BOOT_CPU_ID_COUNT]);

#endif /* LIBERX_BACKEND_CORE_CPU_FEATURES_H */
