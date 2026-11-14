/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

/*
 * Host driver of liberx/backend/core/arch/aarch64/cpu_features.c: takes the
 * identification words ISAR0 ISAR1 ISAR2 PFR0 PFR1 in hex and prints the
 * feature words they give as musl's names, "hwcap NAME... hwcap2 NAME...",
 * and "unnamed" for any bit musl's header does not name.
 */

#include <inttypes.h>
#include <stdio.h>
#include <stdlib.h>

#include "erx/abi.h"
#include "liberx/backend/core/cpu_features.h"
#include "musl/arch/aarch64/bits/hwcap.h"

typedef struct named_bit {
	const char	*name;
	uint64_t	 bit;
} named_bit_t;

#define NAMED(word, name)	{ #name, (uint64_t)(word##_##name) }

static const named_bit_t hwcap_names[] = {
	NAMED(HWCAP, FP), NAMED(HWCAP, ASIMD), NAMED(HWCAP, EVTSTRM), NAMED(HWCAP, AES),
	NAMED(HWCAP, PMULL), NAMED(HWCAP, SHA1), NAMED(HWCAP, SHA2), NAMED(HWCAP, CRC32),
	NAMED(HWCAP, ATOMICS), NAMED(HWCAP, FPHP), NAMED(HWCAP, ASIMDHP), NAMED(HWCAP, CPUID),
	NAMED(HWCAP, ASIMDRDM), NAMED(HWCAP, JSCVT), NAMED(HWCAP, FCMA), NAMED(HWCAP, LRCPC),
	NAMED(HWCAP, DCPOP), NAMED(HWCAP, SHA3), NAMED(HWCAP, SM3), NAMED(HWCAP, SM4),
	NAMED(HWCAP, ASIMDDP), NAMED(HWCAP, SHA512), NAMED(HWCAP, SVE), NAMED(HWCAP, ASIMDFHM),
	NAMED(HWCAP, DIT), NAMED(HWCAP, USCAT), NAMED(HWCAP, ILRCPC), NAMED(HWCAP, FLAGM),
	NAMED(HWCAP, SSBS), NAMED(HWCAP, SB), NAMED(HWCAP, PACA), NAMED(HWCAP, PACG),
};

static const named_bit_t hwcap2_names[] = {
	NAMED(HWCAP2, DCPODP), NAMED(HWCAP2, SVE2), NAMED(HWCAP2, SVEAES), NAMED(HWCAP2, SVEPMULL),
	NAMED(HWCAP2, SVEBITPERM), NAMED(HWCAP2, SVESHA3), NAMED(HWCAP2, SVESM4), NAMED(HWCAP2, FLAGM2),
	NAMED(HWCAP2, FRINT), NAMED(HWCAP2, SVEI8MM), NAMED(HWCAP2, SVEF32MM), NAMED(HWCAP2, SVEF64MM),
	NAMED(HWCAP2, SVEBF16), NAMED(HWCAP2, I8MM), NAMED(HWCAP2, BF16), NAMED(HWCAP2, DGH),
	NAMED(HWCAP2, RNG), NAMED(HWCAP2, BTI), NAMED(HWCAP2, MTE),
};

/* The handoff word each argument fills, in the order the arguments come. */
static const uint32_t argument_words[] = {
	ERX_CPU_ID_WORD_AA64ISAR0, ERX_CPU_ID_WORD_AA64ISAR1, ERX_CPU_ID_WORD_AA64ISAR2,
	ERX_CPU_ID_WORD_AA64PFR0, ERX_CPU_ID_WORD_AA64PFR1,
};

#define ARGUMENTS	(sizeof(argument_words) / sizeof(argument_words[0]))

static void
print_word(const char *label, uint64_t word, const named_bit_t *names, size_t count)
{
	printf("%s", label);
	for (size_t index = 0; index < count; index++) {
		if ((word & names[index].bit) != 0) {
			printf(" %s", names[index].name);
			word &= ~names[index].bit;
		}
	}
	if (word != 0)
		printf(" unnamed");
}

int
main(int argc, char **argv)
{
	uint64_t id[ERX_BOOT_CPU_ID_COUNT] = { 0 };
	erx_cpu_features_t features;

	if ((size_t)argc != 1 + ARGUMENTS)
		return (2);
	for (size_t index = 0; index < ARGUMENTS; index++)
		id[argument_words[index]] = strtoull(argv[1 + index], NULL, 16);
	features = erx_cpu_features(id);
	print_word("hwcap", features.hwcap, hwcap_names, sizeof(hwcap_names) / sizeof(hwcap_names[0]));
	print_word(" hwcap2", features.hwcap2, hwcap2_names, sizeof(hwcap2_names) / sizeof(hwcap2_names[0]));
	printf("\n");
	return (0);
}
