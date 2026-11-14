/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

/*
 * The boot CPU's identification registers, read in kernel mode by bootstrap,
 * which links this file (tools/lib/erx/core_archive.rb, BOOT_SOURCES): user
 * mode cannot read them, and the stopgap kernel publishes no copy. Only the
 * boot CPU is read (TODO.md). The reads are the generated accessors of
 * hw/sysreg/aarch64.json, and this is the one file that calls them (the
 * sysreg-read chokepoint).
 */

#include <stdint.h>

#include "erx/arch/aarch64/cpu_id.h"
#include "erx/arch/aarch64/sysreg.h"
#include "erx/core/boot_handoff.h"

_Static_assert(ERX_CPU_ID_WORDS <= ERX_BOOT_CPU_ID_COUNT,
    "the handoff holds every identification register read");

void
erx_boot_cpu_id_read(uint64_t id[ERX_BOOT_CPU_ID_COUNT])
{
	for (int index = 0; index < ERX_BOOT_CPU_ID_COUNT; index++)
		id[index] = 0;
	id[ERX_CPU_ID_AA64ISAR0] = erx_sysreg_id_aa64isar0_el1_read();
	id[ERX_CPU_ID_AA64ISAR1] = erx_sysreg_id_aa64isar1_el1_read();
	id[ERX_CPU_ID_AA64ISAR2] = erx_sysreg_id_aa64isar2_el1_read();
	id[ERX_CPU_ID_AA64PFR0] = erx_sysreg_id_aa64pfr0_el1_read();
	id[ERX_CPU_ID_AA64PFR1] = erx_sysreg_id_aa64pfr1_el1_read();
}
