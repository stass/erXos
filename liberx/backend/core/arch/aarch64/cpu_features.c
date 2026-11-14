/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

/*
 * AT_HWCAP and AT_HWCAP2 from the boot CPU's identification registers, in two
 * steps (docs/design-arch-aarch64.md, "CPU feature words"):
 *
 * 1. decode: each feature field's value against the least value that has the
 *    feature, as FreeBSD 15.1.0 maps them (sys/arm64/arm64/identcpu.c,
 *    parse_cpu_features and its MRS_HWCAP tables; the values are its
 *    sys/arm64/include/armreg.h's). The fields' positions are Arm's, through
 *    the accessors generated from hw/sysreg/aarch64.json, and the bits are
 *    musl's own, from its arch/aarch64/bits/hwcap.h.
 * 2. allow: only the bits of CLAIMED_HWCAP and CLAIMED_HWCAP2 survive, the
 *    features the stopgap kernel enables for user mode and whose state it
 *    saves on a switch. A bit for state the kernel does not save (SVE's
 *    vectors, say) would let one thread see another's registers, so decode
 *    may say present and allow still drops it.
 *
 * Nothing here reads a register: the words come from the handoff.
 */

#include <stdint.h>

#include "erx/arch/aarch64/cpu_id.h"
#include "erx/arch/aarch64/sysreg_fields.h"
#include "liberx/backend/core/cpu_features.h"
#include "musl/arch/aarch64/bits/hwcap.h"

_Static_assert(ERX_CPU_ID_WORDS <= ERX_BOOT_CPU_ID_COUNT,
    "the handoff holds every identification register decode reads");

/*
 * What the stopgap gives user mode, from Fiasco's kern/arm sources: FP and
 * SIMD are on (CONFIG_FPU, which tools/lib/erx/fiasco_config.rb requires) and
 * saved whole on every switch, q0-q31 with FPCR and FPSR
 * (64/fpu-arm.cpp:211-243), so the FP and SIMD instruction sets below cost no
 * state of their own; FLAGM's flags live in PSTATE, saved on every entry;
 * DC CVAP from user mode needs SCTLR_EL1.UCI, which Sctlr_el1_generic sets
 * (64/cpu-arm-64.cpp:43-49). Never claimed: SVE (CONFIG_ARM_SVE is forbidden,
 * so its state is neither enabled nor saved), pointer authentication and BTI
 * (Sctlr_el1_generic leaves EnIA, EnIB, EnDA, EnDB and BT0 clear), and
 * CPUID (user mode cannot read the identification registers, and Fiasco
 * emulates no such read). What else decode finds stays out until each is
 * checked against the stopgap.
 */
#define CLAIMED_HWCAP	(HWCAP_FP | HWCAP_ASIMD | HWCAP_FPHP | HWCAP_ASIMDHP | HWCAP_AES | \
	HWCAP_PMULL | HWCAP_SHA1 | HWCAP_SHA2 | HWCAP_SHA512 | HWCAP_SHA3 | HWCAP_SM3 | HWCAP_SM4 | \
	HWCAP_CRC32 | HWCAP_ATOMICS | HWCAP_ASIMDDP | HWCAP_FCMA | HWCAP_JSCVT | HWCAP_LRCPC | \
	HWCAP_ILRCPC | HWCAP_DCPOP | HWCAP_FLAGM)
#define CLAIMED_HWCAP2	0

static erx_cpu_features_t	decode(const uint64_t id[ERX_BOOT_CPU_ID_COUNT]);

erx_cpu_features_t
erx_cpu_features(const uint64_t id[ERX_BOOT_CPU_ID_COUNT])
{
	const erx_cpu_features_t present = decode(id);

	return ((erx_cpu_features_t){ .hwcap = present.hwcap & (uint64_t)(CLAIMED_HWCAP),
	    .hwcap2 = present.hwcap2 & (uint64_t)(CLAIMED_HWCAP2) });
}

/* bit when an unsigned 4-bit feature field is at least least. */
static uint64_t
at_least(uint64_t field, uint64_t least, uint64_t bit)
{
	return (field >= least ? bit : 0);
}

/*
 * bit when a signed 4-bit feature field is at least least, compared as
 * identcpu.c's mrs_field_cmp compares them: 0xf (-1) says absent, 0 present.
 */
static uint64_t
signed_at_least(uint64_t field, uint64_t least, uint64_t bit)
{
	return ((field ^ 0x8) >= (least ^ 0x8) ? bit : 0);
}

/*
 * Every feature the words say the CPU has, whether or not the kernel enables it, and
 * CPUID, which FreeBSD claims for every CPU: decode is FreeBSD's mapping whole, and
 * what the stopgap cannot honour is allow's to drop.
 */
static erx_cpu_features_t
decode(const uint64_t id[ERX_BOOT_CPU_ID_COUNT])
{
	const uint64_t isar0 = id[ERX_CPU_ID_AA64ISAR0];
	const uint64_t isar1 = id[ERX_CPU_ID_AA64ISAR1];
	const uint64_t isar2 = id[ERX_CPU_ID_AA64ISAR2];
	const uint64_t pfr0 = id[ERX_CPU_ID_AA64PFR0];
	const uint64_t pfr1 = id[ERX_CPU_ID_AA64PFR1];
	uint64_t hwcap = 0, hwcap2 = 0;

	/*
	 * CPUID says user mode may read the identification registers, which FreeBSD
	 * claims on every CPU because its kernel emulates the read (identcpu.c:2864).
	 * The stopgap does not, and a program that read them on its word (OpenSSL's
	 * armcap.c reads MIDR_EL1) would fault, so allow always drops it.
	 */
	hwcap |= HWCAP_CPUID;

	/* ID_AA64PFR0_EL1 (identcpu.c:1649-1716); FP and AdvSIMD are signed (:1757-1759). */
	hwcap |= signed_at_least(erx_sysreg_id_aa64pfr0_el1_fp_get(pfr0), 0, HWCAP_FP);
	hwcap |= signed_at_least(erx_sysreg_id_aa64pfr0_el1_fp_get(pfr0), 1, HWCAP_FPHP);
	hwcap |= signed_at_least(erx_sysreg_id_aa64pfr0_el1_advsimd_get(pfr0), 0, HWCAP_ASIMD);
	hwcap |= signed_at_least(erx_sysreg_id_aa64pfr0_el1_advsimd_get(pfr0), 1, HWCAP_ASIMDHP);
	hwcap |= at_least(erx_sysreg_id_aa64pfr0_el1_sve_get(pfr0), 1, HWCAP_SVE);
	hwcap |= at_least(erx_sysreg_id_aa64pfr0_el1_dit_get(pfr0), 1, HWCAP_DIT);

	/* ID_AA64PFR1_EL1 (identcpu.c:1849-1860). */
	hwcap |= at_least(erx_sysreg_id_aa64pfr1_el1_ssbs_get(pfr1), 1, HWCAP_SSBS);
	hwcap2 |= at_least(erx_sysreg_id_aa64pfr1_el1_bt_get(pfr1), 1, HWCAP2_BTI);

	/* ID_AA64ISAR0_EL1 (identcpu.c:676-816). */
	hwcap |= at_least(erx_sysreg_id_aa64isar0_el1_aes_get(isar0), 1, HWCAP_AES);
	hwcap |= at_least(erx_sysreg_id_aa64isar0_el1_aes_get(isar0), 2, HWCAP_PMULL);
	hwcap |= at_least(erx_sysreg_id_aa64isar0_el1_sha1_get(isar0), 1, HWCAP_SHA1);
	hwcap |= at_least(erx_sysreg_id_aa64isar0_el1_sha2_get(isar0), 1, HWCAP_SHA2);
	hwcap |= at_least(erx_sysreg_id_aa64isar0_el1_sha2_get(isar0), 2, HWCAP_SHA512);
	hwcap |= at_least(erx_sysreg_id_aa64isar0_el1_crc32_get(isar0), 1, HWCAP_CRC32);
	hwcap |= at_least(erx_sysreg_id_aa64isar0_el1_atomic_get(isar0), 2, HWCAP_ATOMICS);
	hwcap |= at_least(erx_sysreg_id_aa64isar0_el1_rdm_get(isar0), 1, HWCAP_ASIMDRDM);
	hwcap |= at_least(erx_sysreg_id_aa64isar0_el1_sha3_get(isar0), 1, HWCAP_SHA3);
	hwcap |= at_least(erx_sysreg_id_aa64isar0_el1_sm3_get(isar0), 1, HWCAP_SM3);
	hwcap |= at_least(erx_sysreg_id_aa64isar0_el1_sm4_get(isar0), 1, HWCAP_SM4);
	hwcap |= at_least(erx_sysreg_id_aa64isar0_el1_dp_get(isar0), 1, HWCAP_ASIMDDP);
	hwcap |= at_least(erx_sysreg_id_aa64isar0_el1_fhm_get(isar0), 1, HWCAP_ASIMDFHM);
	hwcap |= at_least(erx_sysreg_id_aa64isar0_el1_ts_get(isar0), 1, HWCAP_FLAGM);
	hwcap2 |= at_least(erx_sysreg_id_aa64isar0_el1_ts_get(isar0), 2, HWCAP2_FLAGM2);
	hwcap2 |= at_least(erx_sysreg_id_aa64isar0_el1_rndr_get(isar0), 1, HWCAP2_RNG);

	/* ID_AA64ISAR1_EL1 (identcpu.c:871-1017). */
	hwcap |= at_least(erx_sysreg_id_aa64isar1_el1_dpb_get(isar1), 1, HWCAP_DCPOP);
	hwcap2 |= at_least(erx_sysreg_id_aa64isar1_el1_dpb_get(isar1), 2, HWCAP2_DCPODP);
	hwcap |= at_least(erx_sysreg_id_aa64isar1_el1_apa_get(isar1), 1, HWCAP_PACA);
	hwcap |= at_least(erx_sysreg_id_aa64isar1_el1_api_get(isar1), 1, HWCAP_PACA);
	hwcap |= at_least(erx_sysreg_id_aa64isar1_el1_jscvt_get(isar1), 1, HWCAP_JSCVT);
	hwcap |= at_least(erx_sysreg_id_aa64isar1_el1_fcma_get(isar1), 1, HWCAP_FCMA);
	hwcap |= at_least(erx_sysreg_id_aa64isar1_el1_lrcpc_get(isar1), 1, HWCAP_LRCPC);
	hwcap |= at_least(erx_sysreg_id_aa64isar1_el1_lrcpc_get(isar1), 2, HWCAP_ILRCPC);
	hwcap |= at_least(erx_sysreg_id_aa64isar1_el1_gpa_get(isar1), 1, HWCAP_PACG);
	hwcap |= at_least(erx_sysreg_id_aa64isar1_el1_gpi_get(isar1), 1, HWCAP_PACG);
	hwcap2 |= at_least(erx_sysreg_id_aa64isar1_el1_frintts_get(isar1), 1, HWCAP2_FRINT);
	hwcap |= at_least(erx_sysreg_id_aa64isar1_el1_sb_get(isar1), 1, HWCAP_SB);
	hwcap2 |= at_least(erx_sysreg_id_aa64isar1_el1_bf16_get(isar1), 1, HWCAP2_BF16);
	hwcap2 |= at_least(erx_sysreg_id_aa64isar1_el1_dgh_get(isar1), 1, HWCAP2_DGH);
	hwcap2 |= at_least(erx_sysreg_id_aa64isar1_el1_i8mm_get(isar1), 1, HWCAP2_I8MM);

	/* ID_AA64ISAR2_EL1 (identcpu.c:1114-1124): the third pointer-authentication algorithm. */
	hwcap |= at_least(erx_sysreg_id_aa64isar2_el1_apa3_get(isar2), 1, HWCAP_PACA);
	hwcap |= at_least(erx_sysreg_id_aa64isar2_el1_gpa3_get(isar2), 1, HWCAP_PACG);
	return ((erx_cpu_features_t){ .hwcap = hwcap, .hwcap2 = hwcap2 });
}
