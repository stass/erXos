/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

/*
 * What a program's first thread hands musl, in the root and in a task alike: the block
 * musl expects on a program's first stack, argv, then envp, then the auxiliary vector,
 * which musl finds past envp's NULL (musl's src/env/__libc_start_main.c:28). The block
 * holds one argument, no environment, the program headers, which is how musl's static
 * start finds the TLS image, the page size, the CPU feature words and AT_RANDOM. Nothing
 * else in it matters to musl here. musl writes the vector too: its aarch64
 * __set_thread_area masks feature bits it cannot support out of AT_HWCAP and AT_HWCAP2
 * (src/thread/aarch64/__set_thread_area.c:13-24), so the block is writable memory.
 *
 * AT_RANDOM names 16 bytes from the generator. musl's start takes the stack protector's
 * guard from the first 8 (src/env/__stack_chk_fail.c:9) and mallocng its secret from the
 * last 8 (src/malloc/mallocng/glue.h:47-49). They stay in the block for the program's
 * life, as a kernel's loader leaves them on the first stack (FreeBSD 15.1.0's
 * sys/compat/linux/linux_elf.c:359-361 writes them there and :526 points AT_RANDOM at
 * them), so getauxval(AT_RANDOM) names them while the program runs. Without AT_RANDOM
 * musl would derive both secrets from an address (__stack_chk_fail.c:10, glue.h:46),
 * so a start whose generator refuses the bytes does not run the program at all.
 */

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#include "erx/abi.h"
#include "liberx/backend/api.h"
#include "liberx/backend/fiasco/libc_start.h"
#include "liberx/backend/fiasco/task_start.h"

/* What AT_RANDOM names: the two 64-bit words musl reads. */
#define RANDOM_WORDS	2u

typedef struct aux_entry {
	uintptr_t	key;
	uintptr_t	value;
} aux_entry_t;

/*
 * Laid out as musl reads it: argv, then envp, then the auxiliary vector, without gaps.
 * random is what AT_RANDOM points at; musl reads it only through that pointer.
 */
typedef struct start_block {
	char		*argv[2];
	char		*envp[1];
	aux_entry_t	aux_phdr;
	aux_entry_t	aux_phent;
	aux_entry_t	aux_phnum;
	aux_entry_t	aux_pagesz;
	aux_entry_t	aux_hwcap;
	aux_entry_t	aux_hwcap2;
	aux_entry_t	aux_random;
	aux_entry_t	aux_null;
	uint64_t	random[RANDOM_WORDS];
} start_block_t;

/* musl walks argv, envp and the vector as one array of words, so no field may leave a gap. */
_Static_assert(offsetof(start_block_t, envp) == sizeof(((start_block_t *)0)->argv), "envp follows argv");
_Static_assert(offsetof(start_block_t, aux_phdr) == offsetof(start_block_t, envp) + sizeof(char *),
    "the vector follows envp's NULL");
_Static_assert(offsetof(start_block_t, random) == offsetof(start_block_t, aux_null) + sizeof(aux_entry_t),
    "AT_NULL ends the vector, and random lies past it");
_Static_assert(sizeof(aux_entry_t) == 2 * sizeof(uintptr_t), "an entry is two words");
_Static_assert(RANDOM_WORDS * sizeof(uint64_t) <= ERX_ENTROPY_BYTES_MAX, "AT_RANDOM's bytes take one generator read");

/* The linker's name for the ELF headers, which root.ld and task.ld load first. */
extern const erx_elf64_ehdr_t __ehdr_start;

int	__libc_start_main(int (*)(int, char **, char **), int, char **, void (*)(void), void (*)(void), void (*)(void));

static bool	random_fill(uint64_t words[RANDOM_WORDS]);

static char program_name[] = "erxos";
static start_block_t start_block;

int64_t
erx_fiasco_libc_start(int (*program)(int, char **, char **), erx_fiasco_cpu_features_t features)
{
	if (!random_fill(start_block.random))
		return (ERX_FIASCO_TASK_STATUS_ENTROPY);
	start_block.argv[0] = program_name;
	start_block.aux_phdr = (aux_entry_t){ ERX_ELF_AT_PHDR,
	    (uintptr_t)&__ehdr_start + (uintptr_t)__ehdr_start.e_phoff };
	start_block.aux_phent = (aux_entry_t){ ERX_ELF_AT_PHENT, __ehdr_start.e_phentsize };
	start_block.aux_phnum = (aux_entry_t){ ERX_ELF_AT_PHNUM, __ehdr_start.e_phnum };
	start_block.aux_pagesz = (aux_entry_t){ ERX_ELF_AT_PAGESZ, ERX_PAGE_SIZE };
	start_block.aux_hwcap = (aux_entry_t){ ERX_ELF_AT_HWCAP, features.hwcap };
	start_block.aux_hwcap2 = (aux_entry_t){ ERX_ELF_AT_HWCAP2, features.hwcap2 };
	start_block.aux_random = (aux_entry_t){ ERX_ELF_AT_RANDOM, (uintptr_t)start_block.random };
	start_block.aux_null = (aux_entry_t){ ERX_ELF_AT_NULL, 0 };
	(void)__libc_start_main(program, 1, start_block.argv, NULL, NULL, NULL);
	return (ERX_FIASCO_TASK_STATUS_LIBC);
}

/*
 * One generator read of AT_RANDOM's bytes, taken out of this thread's UTCB mr and each word
 * zeroed there as it is taken, as the getrandom row of musl's seam does, so only the block
 * holds them. false when the generator refused them; erx_entropy_read then left mr zeroed,
 * and words is untouched.
 */
static bool
random_fill(uint64_t words[RANDOM_WORDS])
{
	erx_utcb_t *const utcb = erx_utcb_self();

	if (erx_entropy_read(RANDOM_WORDS * sizeof(uint64_t)) != ERX_OK)
		return (false);
	for (uint32_t word = 0; word < RANDOM_WORDS; word++) {
		(void)erx_utcb_mr_load(utcb, word, &words[word]);
		(void)erx_utcb_mr_store(utcb, word, 0);
	}
	return (true);
}
