/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

#ifndef ERX_BACKEND_BOOT_INFO_H
#define ERX_BACKEND_BOOT_INFO_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#include "erx/abi.h"
#include "erx/cdefs.h"

/*
 * The boot information page (docs/design-stopgap.md, "Boot information"), made and read
 * by pure functions over the memory they are handed, so both entries write the same page
 * and ERTS's start reads it one way.
 *
 * After the fixed part, and the root extension when ERX_BOOT_ROOT is set, come the
 * strings: the node name, then the arguments, then the environment. A word list is words
 * each ended by a NUL, with no empty word, and an environment word is KEY=VALUE with a
 * key. The node name, <id>@<host>, has no NUL of its own.
 */

typedef enum erx_boot_info_status {
	ERX_BOOT_INFO_OK = 0,
	ERX_BOOT_INFO_TOO_SMALL,	/* the page cannot hold it */
	ERX_BOOT_INFO_VERSION,		/* a page of another version */
	ERX_BOOT_INFO_ABI_VERSION,	/* a page of another ABI */
	ERX_BOOT_INFO_FLAGS,		/* a flag this build does not know */
	ERX_BOOT_INFO_RESERVED,		/* a reserved word that is not zero */
	ERX_BOOT_INFO_STRINGS,		/* more than ERX_BOOT_STRINGS_MAX of strings */
	ERX_BOOT_INFO_BOUNDS,		/* a string outside the page */
	ERX_BOOT_INFO_NODE,		/* a node name not of the form <id>@<host> */
	ERX_BOOT_INFO_WORDS,		/* an empty word, or a list not ended by a NUL */
	ERX_BOOT_INFO_ENV		/* an environment word that is not KEY=VALUE */
} erx_boot_info_status_t;

/*
 * Some words of a list: NUL-separated, with the last one's NUL optional, so a word cut
 * from a command line and a list from the manifest are given the same way.
 */
typedef struct erx_boot_words {
	const char	*bytes;
	size_t		 length;
} erx_boot_words_t;

/* What an entry gathers. Every other field of the page has one value on both entries. */
typedef struct erx_boot_inputs {
	uint32_t		 domain_id;
	uint32_t		 flags;
	uint32_t		 pack_flags;
	uint32_t		 capacity_mcpu;
	erx_cap_t		 budget;	/* a domain's: the values its installs gave */
	erx_cap_t		 space;		/* ERX_CAP_SELF, as every space names itself */
	erx_cap_t		 group;
	erx_cap_t		 spaces_group;	/* a domain's with ERX_DOM_SPACES: its sub-space group */
	erx_cap_t		 time_page;
	erx_cap_t		 release;
	erx_cap_t		 crash_area;
	erx_boot_connection_t	 system_connection;	/* its peer node fields left 0 (TODO.md) */
	uint64_t		 release_addr;
	uint64_t		 cpuset;
	const char		*node;
	size_t			 node_len;
	const erx_boot_words_t	*args;
	size_t			 nargs;
	const erx_boot_words_t	*env;
	size_t			 nenv;
	erx_runtime_limits_t	 limits;
} erx_boot_inputs_t;

/* A page's fields, and where its strings lie. A string of length zero has no pointer to follow. */
typedef struct erx_boot_view {
	erx_boot_info_t	 info;
	const char	*node;
	const char	*args;
	const char	*env;
} erx_boot_view_t;

/* What a vector for erl_start takes: argc, and the bytes of its strings. */
typedef struct erx_boot_argv_plan {
	size_t	argc;
	size_t	strings;
} erx_boot_argv_plan_t;

/* Writes the page, or refuses and leaves it untouched. size is what page holds. */
erx_boot_info_status_t	erx_boot_info_build(const erx_boot_inputs_t *inputs, void *page, size_t size) ERX_WARN_UNUSED_RESULT;
/* Checks every field and string of size bytes at page, at any alignment. */
erx_boot_info_status_t	erx_boot_info_read(const void *page, size_t size, erx_boot_view_t *view) ERX_WARN_UNUSED_RESULT;
const char		*erx_boot_info_reason(erx_boot_info_status_t status);

/*
 * The vector from a page erx_boot_info_read accepted: beam, its words, then -name under a
 * dotted host or -sname otherwise, and the node name. argv takes argc + 1 pointers and
 * strings the plan's bytes; both are the caller's, since erl_start edits what it is given.
 */
erx_boot_argv_plan_t	erx_boot_argv_plan(const erx_boot_view_t *view);
void			erx_boot_argv_fill(const erx_boot_view_t *view, char **argv, char *strings);

#endif /* ERX_BACKEND_BOOT_INFO_H */
