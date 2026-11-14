/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

/*
 * AT_HWCAP and AT_HWCAP2 from the boot CPU's identification registers
 * (docs/design-arch-aarch64.md, "CPU feature words"). The table in
 * erx_cpu_features has one row for each feature the stopgap kernel lets user
 * mode use, and a feature's bit is set when its field is at least the least
 * value that has it. Fields are read through the accessors generated from
 * hw/sysreg/aarch64.json; the least values are FreeBSD 15.1.0's
 * (sys/arm64/arm64/identcpu.c, its MRS_HWCAP tables, with the values of its
 * sys/arm64/include/armreg.h); the bits are musl's own, from its
 * arch/aarch64/bits/hwcap.h.
 *
 * A feature gets a row only once the stopgap is shown to enable it for user
 * mode and to save its state on a switch, and the row's comment cites where,
 * in Fiasco's sources under fiasco/kernel/src/kern/arm: a bit for state the
 * kernel does not save would let one thread see another's registers. Without
 * a row, and so never claimed: SVE (CONFIG_ARM_SVE is forbidden, so its state
 * is neither enabled nor saved); pointer authentication and BTI
 * (Sctlr_el1_generic, 64/cpu-arm-64.cpp:43-49, leaves EnIA, EnIB, EnDA, EnDB
 * and BT0 clear); MTE; and CPUID, which FreeBSD claims on every CPU because
 * its kernel emulates user mode's reads of the identification registers
 * (identcpu.c:2864). Fiasco emulates none, and a program that read them on
 * CPUID's word (OpenSSL's armcap.c reads MIDR_EL1) would fault. No AT_HWCAP2
 * feature has a row; a row names its bit in either word.
 *
 * Nothing here reads a register: the words come from the handoff.
 */

#include <stddef.h>
#include <stdint.h>

#include "erx/abi.h"
#include "erx/arch/aarch64/sysreg_fields.h"
#include "liberx/backend/core/cpu_features.h"
#include "musl/arch/aarch64/bits/hwcap.h"

/* A feature field's value, the least value that has the feature, and its bit. */
typedef struct claim {
	int			 value;
	int			 least;
	erx_cpu_features_t	 bit;
} claim_t;

/*
 * A signed 4-bit feature field's value, as identcpu.c's mrs_field_cmp (:2491)
 * compares the fields its table marks signed, FP and AdvSIMD (:1757-1760):
 * 0xf, -1, says absent and 0 present.
 */
static int
signed_field(uint64_t field)
{
	return ((int)(field ^ 0x8) - 0x8);
}

erx_cpu_features_t
erx_cpu_features(const uint64_t id[ERX_BOOT_CPU_ID_COUNT])
{
	/* Each word read lies in the handoff, which the parameter's type does not check. */
	_Static_assert(ERX_CPU_ID_WORD_AA64PFR0 < ERX_BOOT_CPU_ID_COUNT, "PFR0 is a handoff word");
	_Static_assert(ERX_CPU_ID_WORD_AA64ISAR0 < ERX_BOOT_CPU_ID_COUNT, "ISAR0 is a handoff word");
	_Static_assert(ERX_CPU_ID_WORD_AA64ISAR1 < ERX_BOOT_CPU_ID_COUNT, "ISAR1 is a handoff word");
	const uint64_t pfr0 = id[ERX_CPU_ID_WORD_AA64PFR0];
	const uint64_t isar0 = id[ERX_CPU_ID_WORD_AA64ISAR0];
	const uint64_t isar1 = id[ERX_CPU_ID_WORD_AA64ISAR1];
	const claim_t claims[] = {
		/*
		 * FP and SIMD, with their half-precision forms (identcpu.c:1703-1716):
		 * enabled (CONFIG_FPU, which tools/lib/erx/fiasco_config.rb requires)
		 * and saved whole on every switch, q0-q31 with FPCR and FPSR
		 * (64/fpu-arm.cpp:211-243), since the same file forbids CONFIG_LAZY_FPU.
		 */
		{ signed_field(erx_sysreg_id_aa64pfr0_el1_fp_get(pfr0)), 0, { .hwcap = HWCAP_FP } },
		{ signed_field(erx_sysreg_id_aa64pfr0_el1_fp_get(pfr0)), 1, { .hwcap = HWCAP_FPHP } },
		{ signed_field(erx_sysreg_id_aa64pfr0_el1_advsimd_get(pfr0)), 0, { .hwcap = HWCAP_ASIMD } },
		{ signed_field(erx_sysreg_id_aa64pfr0_el1_advsimd_get(pfr0)), 1, { .hwcap = HWCAP_ASIMDHP } },

		/*
		 * Instructions over the FP and SIMD registers above, so they have no
		 * state of their own; JSCVT also writes a general register and the flags,
		 * saved as the next group says (identcpu.c:716, :726, :736, :746,
		 * :792-793, :803, :814-815, :962, :972).
		 */
		{ erx_sysreg_id_aa64isar0_el1_aes_get(isar0), 1, { .hwcap = HWCAP_AES } },
		{ erx_sysreg_id_aa64isar0_el1_aes_get(isar0), 2, { .hwcap = HWCAP_PMULL } },
		{ erx_sysreg_id_aa64isar0_el1_sha1_get(isar0), 1, { .hwcap = HWCAP_SHA1 } },
		{ erx_sysreg_id_aa64isar0_el1_sha2_get(isar0), 1, { .hwcap = HWCAP_SHA2 } },
		{ erx_sysreg_id_aa64isar0_el1_sha2_get(isar0), 2, { .hwcap = HWCAP_SHA512 } },
		{ erx_sysreg_id_aa64isar0_el1_sha3_get(isar0), 1, { .hwcap = HWCAP_SHA3 } },
		{ erx_sysreg_id_aa64isar0_el1_sm3_get(isar0), 1, { .hwcap = HWCAP_SM3 } },
		{ erx_sysreg_id_aa64isar0_el1_sm4_get(isar0), 1, { .hwcap = HWCAP_SM4 } },
		{ erx_sysreg_id_aa64isar0_el1_dp_get(isar0), 1, { .hwcap = HWCAP_ASIMDDP } },
		{ erx_sysreg_id_aa64isar1_el1_fcma_get(isar1), 1, { .hwcap = HWCAP_FCMA } },
		{ erx_sysreg_id_aa64isar1_el1_jscvt_get(isar1), 1, { .hwcap = HWCAP_JSCVT } },

		/*
		 * Instructions whose operands are the general registers and PSTATE's
		 * flags, which every kernel entry saves (64/ivt.S:33-52 and :293-296)
		 * and every return restores (:54-73 and :75-79) (identcpu.c:695, :771,
		 * :781, :951-952).
		 */
		{ erx_sysreg_id_aa64isar0_el1_crc32_get(isar0), 1, { .hwcap = HWCAP_CRC32 } },
		{ erx_sysreg_id_aa64isar0_el1_atomic_get(isar0), 2, { .hwcap = HWCAP_ATOMICS } },
		{ erx_sysreg_id_aa64isar0_el1_ts_get(isar0), 1, { .hwcap = HWCAP_FLAGM } },
		{ erx_sysreg_id_aa64isar1_el1_lrcpc_get(isar1), 1, { .hwcap = HWCAP_LRCPC } },
		{ erx_sysreg_id_aa64isar1_el1_lrcpc_get(isar1), 2, { .hwcap = HWCAP_ILRCPC } },

		/*
		 * DC CVAP, which user mode may issue because Sctlr_el1_generic sets
		 * SCTLR_EL1.UCI (64/cpu-arm-64.cpp:43-49; identcpu.c:1016).
		 */
		{ erx_sysreg_id_aa64isar1_el1_dpb_get(isar1), 1, { .hwcap = HWCAP_DCPOP } },
	};
	erx_cpu_features_t features = { 0 };

	for (size_t index = 0; index < sizeof(claims) / sizeof(claims[0]); index++) {
		if (claims[index].value >= claims[index].least) {
			features.hwcap |= claims[index].bit.hwcap;
			features.hwcap2 |= claims[index].bit.hwcap2;
		}
	}
	return (features);
}
