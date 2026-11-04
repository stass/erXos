/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

/*
 * What a program's first thread hands musl, in the root and in a task alike: the block
 * musl expects on a program's first stack. The block holds one argument, no
 * environment, and the program headers, which is how musl's static start finds the
 * TLS image. Nothing else in it matters to musl here.
 */

#include <stddef.h>
#include <stdint.h>

#include "erx/abi.h"
#include "liberx/backend/fiasco/libc_start.h"

/* The auxiliary vector's keys musl reads for a static program. */
#define AUX_NULL	0u
#define AUX_PHDR	3u
#define AUX_PHENT	4u
#define AUX_PHNUM	5u
#define AUX_PAGESZ	6u

typedef struct aux_entry {
	uintptr_t	key;
	uintptr_t	value;
} aux_entry_t;

/* Laid out as musl reads it: argv, then envp, then the auxiliary vector, without gaps. */
typedef struct start_block {
	char		*argv[2];
	char		*envp[1];
	aux_entry_t	aux_phdr;
	aux_entry_t	aux_phent;
	aux_entry_t	aux_phnum;
	aux_entry_t	aux_pagesz;
	aux_entry_t	aux_null;
} start_block_t;

/* The linker's name for the ELF headers, which root.ld and task.ld load first. */
extern const erx_elf64_ehdr_t __ehdr_start;

int	main(int, char **, char **);
int	__libc_start_main(int (*)(int, char **, char **), int, char **, void (*)(void), void (*)(void), void (*)(void));

static char program_name[] = "erxos";
static start_block_t start_block;

void
erx_fiasco_libc_start(void)
{
	start_block.argv[0] = program_name;
	start_block.aux_phdr = (aux_entry_t){ AUX_PHDR, (uintptr_t)&__ehdr_start + (uintptr_t)__ehdr_start.e_phoff };
	start_block.aux_phent = (aux_entry_t){ AUX_PHENT, __ehdr_start.e_phentsize };
	start_block.aux_phnum = (aux_entry_t){ AUX_PHNUM, __ehdr_start.e_phnum };
	start_block.aux_pagesz = (aux_entry_t){ AUX_PAGESZ, ERX_PAGE_SIZE };
	start_block.aux_null = (aux_entry_t){ AUX_NULL, 0 };
	(void)__libc_start_main(main, 1, start_block.argv, NULL, NULL, NULL);
}
