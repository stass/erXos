/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

#ifndef ERX_ARCH_AARCH64_CPU_ID_H
#define ERX_ARCH_AARCH64_CPU_ID_H

/*
 * Where each identification register of the boot CPU lies in the handoff's
 * cpu_id words (abi/kernel.txt, erx_boot_handoff): bootstrap's reader,
 * kernel/arch/aarch64/cpu_id.c, writes them in this order, and the root's
 * feature core, liberx/backend/core/arch/aarch64/cpu_features.c, reads them
 * in it. The words from ERX_CPU_ID_WORDS up are 0.
 */
enum {
	ERX_CPU_ID_AA64ISAR0,
	ERX_CPU_ID_AA64ISAR1,
	ERX_CPU_ID_AA64ISAR2,
	ERX_CPU_ID_AA64PFR0,
	ERX_CPU_ID_AA64PFR1,
	ERX_CPU_ID_WORDS
};

#endif /* ERX_ARCH_AARCH64_CPU_ID_H */
