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
 * key. The node name, <name>@<host>, has no NUL of its own.
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
	ERX_BOOT_INFO_NODE,		/* a node name not of the form <name>@<host> */
	ERX_BOOT_INFO_PEER,		/* a system connection with no peer not all zero, or the node as its own peer */
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
	erx_boot_connection_t	 system_connection;	/* its peer node fields from system_node;
							 * all zero without one */
	uint64_t		 release_addr;
	uint64_t		 cpuset;
	uint64_t		 hwcap;		/* the CPU feature words (cpu_features.h) */
	uint64_t		 hwcap2;
	const char		*node;
	size_t			 node_len;
	const char		*system_node;	/* the system connection's peer, or none: length 0 */
	size_t			 system_node_len;
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
	const char	*system_node;	/* the system connection's peer */
	const char	*args;
	const char	*env;
} erx_boot_view_t;

/*
 * What a page lets its ERTS create (docs/design-runtime.md, "Starting a runtime"): the process
 * and atom tables are the startup limits' processes and atoms, and the normal and dirty CPU
 * schedulers are the CPUs of the grant's cpuset, at most ERX_BOOT_ERTS_SCHEDULERS_MAX, with
 * the grant's capacity rounded up online. They reach ERTS as the vector's first flags, which
 * ERTS's own parser checks against its ranges, so a page's flag after them may lower a
 * setting; erx_boot_erts_admit then refuses any setting a flag raised past them. The
 * allocator flags that follow them are the same for every page and are defaults, which a
 * page's flag may change either way (boot_info.c).
 */
#define ERX_BOOT_ERTS_SCHEDULERS_MAX	32	/* a group's 64 executor slots hold both pools */
#define ERX_BOOT_ERTS_PORTS		1024	/* ERTS's least port table, not a startup limit */
#define ERX_BOOT_ERTS_DIRTY_IO		2	/* dirty I/O schedulers, workers that hold no slot */
#define ERX_BOOT_ERTS_WORDS_MAX		128	/* nine flags, their values, and their NULs */

typedef struct erx_boot_erts_limits {
	uint32_t	processes;	/* -P, a power of two, so ERTS's rounding up keeps it */
	uint32_t	atoms;		/* -t */
	uint32_t	schedulers;	/* -S and -SDcpu: those created */
	uint32_t	online;		/* -S and -SDcpu: those online */
} erx_boot_erts_limits_t;

/* What ERTS's arguments left it, read once they are parsed: what erx_boot_erts_admit checks. */
typedef struct erx_boot_erts_settings {
	int64_t	processes;
	int64_t	atoms;
	int64_t	schedulers;
	int64_t	online;
} erx_boot_erts_settings_t;

/* What a vector for erl_start takes: argc, the bytes of its strings, and its first flags. */
typedef struct erx_boot_argv_plan {
	size_t			argc;
	size_t			strings;
	erx_boot_erts_limits_t	limits;
	char			lead[ERX_BOOT_ERTS_WORDS_MAX];	/* the flags limits gives, each NUL-ended */
	size_t			lead_len;
} erx_boot_argv_plan_t;

/* Writes the page, or refuses and leaves it untouched. size is what page holds. */
erx_boot_info_status_t	erx_boot_info_build(const erx_boot_inputs_t *inputs, void *page, size_t size) ERX_WARN_UNUSED_RESULT;
/* Checks every field and string of size bytes at page, at any alignment. */
erx_boot_info_status_t	erx_boot_info_read(const void *page, size_t size, erx_boot_view_t *view) ERX_WARN_UNUSED_RESULT;
const char		*erx_boot_info_reason(erx_boot_info_status_t status);

/*
 * The vector from a page erx_boot_info_read accepted: beam, the flags of the page's ERTS
 * limits, its words, then -name under a dotted host or -sname otherwise, and the node name.
 * The plan refuses a page whose limits ERTS cannot keep, and returns why, or NULL. argv takes
 * argc + 1 pointers and strings the plan's bytes; both are the caller's, since erl_start
 * edits what it is given.
 */
const char		*erx_boot_argv_plan(const erx_boot_view_t *view, erx_boot_argv_plan_t *plan) ERX_WARN_UNUSED_RESULT;
void			 erx_boot_argv_fill(const erx_boot_view_t *view, const erx_boot_argv_plan_t *plan, char **argv,
			    char *strings);
/* NULL when no setting is above limits, or the first one that is. */
const char		*erx_boot_erts_admit(const erx_boot_erts_limits_t *limits, const erx_boot_erts_settings_t *settings);

/*
 * The window of a domain's framebuffer record, `-erx_record framebuffer WINDOW_H OFFSET SIZE ...`
 * among init's arguments, the words after the first `--` (include/erx/boot_words.h): the
 * object the root made over the framebuffer's pages, and the framebuffer's offset and bytes
 * in it. The device NIF maps the framebuffer from this alone (docs/design-runtime.md, "The
 * framebuffer"), so no handle Erlang names is ever mapped as one.
 */
typedef struct erx_boot_framebuffer {
	uint64_t	window;		/* the object's handle */
	uint64_t	offset;		/* the framebuffer's first byte in the object */
	uint64_t	size;		/* the framebuffer's bytes */
} erx_boot_framebuffer_t;

/*
 * The framebuffer record of a page erx_boot_info_read accepted: true with *out for exactly one
 * record whose three numbers are decimal u64s, false for none, a malformed one or more than
 * one. Pure.
 */
bool			 erx_boot_framebuffer(const erx_boot_view_t *view, erx_boot_framebuffer_t *out)
			    ERX_WARN_UNUSED_RESULT;

#endif /* ERX_BACKEND_BOOT_INFO_H */
