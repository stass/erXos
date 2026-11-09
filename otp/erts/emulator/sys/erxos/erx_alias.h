/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 *
 * The alias registry (docs/design-runtime.md, edits 17 and 14, "Representation and aliases"):
 * the domain's active aliases, each from its four identity words to its owner's pid and the
 * holders of the alias as a name of the export table. A reference's words carry no pid and no
 * kind, so the decoder learns that a reference of this node is an active alias, and whose,
 * only here.
 *
 * An entry exists exactly while an origin monitor keyed by the alias, with an alias state
 * set, is in a monitor tree: the monitor tree's own insert and delete functions
 * (erl_monitor_link.c) add and remove it, and unalias/1, which clears the state in place,
 * removes it. No other code adds one, so a peer, which reaches no monitor tree, cannot, and
 * the registry holds no more than the domain's own live aliases, each counted in its
 * owner's monitor memory (erts_monitor_size). It has no count cap of its own: a cap would
 * let one local process, by holding aliases, make every other process's gen_server:call fail.
 */

#ifndef ERX_ALIAS_H
#define ERX_ALIAS_H

#include <stdint.h>

#include "erx_exports_set.h"

/* An alias's identity, as erl_term.h's ERTS_REF_NUMBERS words. */
#define ERX_ALIAS_WORDS		4

/* The stripe an erx_alias_hold took; only erx_alias_release reads it. */
typedef struct erx_alias_hold {
	void		*stripe;
} erx_alias_hold_t;

/* The locks and tables; init_reference calls it before any process exists. */
void		erx_alias_init(void);

/* The bytes an active alias's entry adds to its owner's monitor memory. */
size_t		erx_alias_entry_size(void);

/* Records words as an active alias of owner, an internal pid; nothing if it is recorded. */
void		erx_alias_insert(const uint32_t words[ERX_ALIAS_WORDS], uint64_t owner);

/*
 * Ends the alias words: its entry goes, and its holders are closed, so a peer given it holds
 * nothing. Nothing if words is no active alias.
 */
void		erx_alias_remove(const uint32_t words[ERX_ALIAS_WORDS]);

/*
 * The owner of the active alias words, an internal pid, or 0 when words is none. words is
 * untrusted input: any four words may be asked, and only an entry's exact words answer.
 */
uint64_t	erx_alias_owner(const uint32_t words[ERX_ALIAS_WORDS]);

/*
 * The holders of the active alias words, with the registry's stripe held so the entry cannot
 * end while the caller reads or writes them; NULL, holding nothing, when words is none. The
 * caller ends the hold with erx_alias_release and takes only the export table's own lock in
 * between. Only erx_exports.c calls it.
 */
erx_exports_t	*erx_alias_hold(const uint32_t words[ERX_ALIAS_WORDS], erx_alias_hold_t *hold);
void		erx_alias_release(erx_alias_hold_t *hold);

/* How many aliases are active, for erx_dist:aliases/0. */
uint64_t	erx_alias_count(void);

#endif /* ERX_ALIAS_H */
