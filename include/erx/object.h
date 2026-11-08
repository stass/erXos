/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

#ifndef ERX_OBJECT_H
#define ERX_OBJECT_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#include "erx/abi.h"
#include "erx/cdefs.h"

/*
 * The object store (docs/design-kernel.md, "Objects and capabilities"):
 * the header every kernel object's record begins with, its life as a state
 * that only advances, its counts, the object ids, and the borrowed
 * references a lookup hands out.
 *
 * An object's life:
 *
 * LIVE -----------------------> RELEASED its last capability went | |
 * +--------> DELETED <-----------+ a destroy closed it
 *
 * After erx_object_init makes a header, its state word is written in two
 * places only, which the object chokepoints enforce:
 * erx_object_cap_remove, which only erx_cap_slot_clear and a pass's
 * install that drops what it carried call, writes RELEASED over LIVE;
 * erx_object_close, which only the deletion core calls, writes DELETED.
 * Nothing moves an object back.
 *
 * The records are opaque outside the core: their definitions are in
 * kernel/core/object_impl.h, which only kernel/core/object.c and its host
 * tests include, so no other code writes a header's field. Locks are the
 * caller's: the functions below say which lock their caller holds, and
 * take none themselves.
 */

typedef struct erx_object erx_object_t;
typedef struct erx_object_store erx_object_store_t;

struct erx_budget;

/* An object's state; the numeric order is the order of its life. */
typedef enum erx_obj_state {
	ERX_OBJ_LIVE = 1,	/* named by capabilities, or about to be */
	ERX_OBJ_RELEASED,	/* its last capability went while it was live */
	ERX_OBJ_DELETED		/* closed by a destroy */
} erx_obj_state_t;

/*
 * The key of the object id permutation, a four-round Feistel network on
 * the 64-bit creation counter: one 64-bit key per round, drawn from the
 * entropy generator at boot, or fixed in deterministic mode.
 */
#define ERX_OID_ROUNDS	4

typedef struct erx_oid_key {
	uint64_t	round[ERX_OID_ROUNDS];
} erx_oid_key_t;

/*
 * An object a lookup returned, valid only until its thread's next
 * preemption point of any kind. The thread's count of preemption points
 * travels with it; every point, an explicit one or taking a helping lock,
 * advances the count; and debug and host builds check it at every use, so
 * a pointer kept across a point fails in tests whatever the timing. Only
 * kernel/core/object.c reads or writes the members.
 */
typedef struct erx_uref {
	erx_object_t	*object;
	uint32_t	 epoch;		/* the thread's count at the lookup */
} erx_uref_t;

/*
 * The calling thread's count of preemption points, which the host of the
 * cores keeps: the thread's own on the target, the driver's in host tests.
 */
uint32_t	erx_effect_thread_epoch(void);

/*
 * Starts a store: no object made yet, and the id permutation keyed with
 * key, which is copied. The store is the caller's; nothing global holds
 * the key.
 */
void		erx_object_store_init(erx_object_store_t *store,
		    const erx_oid_key_t *key);

/*
 * Size and alignment of a bare header, and the size of a store, for host
 * tests that hold records without seeing the private header; a kernel
 * object's record embeds a header.
 */
size_t		erx_object_record_size(void);
size_t		erx_object_record_align(void);
size_t		erx_object_store_size(void);

/*
 * Makes object's header: LIVE, no capability, its own counted reference,
 * paid for by budget, its type fixed, and the next object id. Fails with
 * ERX_ELIMIT, writing nothing, once the creation counter is spent, so no
 * id repeats within a boot. The record is the caller's alone until it is
 * published, so no lock is held.
 */
erx_status_t	erx_object_init(erx_object_store_t *store,
		    erx_object_t *object, erx_ktype_t type,
		    struct erx_budget *budget) ERX_WARN_UNUSED_RESULT;

/*
 * The object's state: ERX_OBJ_DELETED once a destroy has closed it, and
 * otherwise LIVE or RELEASED. Read without a lock; it only advances, so a
 * reader that saw a later state never sees an earlier one again.
 */
erx_obj_state_t	erx_object_state(const erx_object_t *object);

/* The fields fixed at creation. */
erx_ktype_t	erx_object_type(const erx_object_t *object);
uint64_t	erx_object_oid(const erx_object_t *object);
struct erx_budget *erx_object_budget(const erx_object_t *object);

/* The number of slots naming the object; under its capability lock. */
uint32_t	erx_object_ncaps(const erx_object_t *object);

/*
 * Counts one more slot naming the object, under its capability lock, as
 * the slot list's insert does before it links the slot. ERX_ESTALE unless
 * the object is LIVE, so no capability is made to a released or closed
 * object; ERX_ELIMIT if the count is full. Nothing changes on failure.
 */
erx_status_t	erx_object_cap_add(erx_object_t *object)
		    ERX_WARN_UNUSED_RESULT;

/*
 * Counts one slot fewer, under the object's capability lock; only
 * erx_cap_slot_clear and erx_pass_install's drop call it. Returns true
 * when that was the last capability, the release the caller reports, and
 * then writes RELEASED if the object is LIVE; a closed object stays
 * DELETED. A removal with no slot counted is a kernel bug and traps.
 */
bool		erx_object_cap_remove(erx_object_t *object)
		    ERX_WARN_UNUSED_RESULT;

/*
 * Closes the object, under its capability lock, so no slot is counted on
 * it once it is closed: writes DELETED in one atomic step and returns
 * true for the one caller that moved it there, the destroy that goes on;
 * every later close returns false. Only the deletion core calls it.
 */
bool		erx_object_close(erx_object_t *object) ERX_WARN_UNUSED_RESULT;

/* The head of the object's slot list; under its capability lock. */
erx_cap_slot_t	*erx_object_slots(const erx_object_t *object);
void		 erx_object_set_slots(erx_object_t *object,
		    erx_cap_slot_t *head);

/*
 * Stamps object with the calling thread's count of preemption points, as
 * the lookup does once it has checked the slot.
 */
erx_uref_t	erx_uref_make(erx_object_t *object);

/*
 * The object of ref. In debug and host builds a ref kept across a
 * preemption point, whose epoch is not the thread's count, traps.
 */
erx_object_t	*erx_uref_get(erx_uref_t ref);

/*
 * Takes a counted reference to ref's object, checking ref as erx_uref_get
 * does, and returns the object. A reference rising from zero means the
 * record's last reference had gone, and a count at its limit means a leak;
 * both are kernel bugs and trap in every build.
 */
erx_object_t	*erx_object_ref(erx_uref_t ref);

/*
 * Drops a counted reference. Returns true when it was the last one, and
 * the record's free is then the caller's to start; a put of a record
 * with no reference traps.
 */
bool		 erx_object_put(erx_object_t *object) ERX_WARN_UNUSED_RESULT;

/*
 * The object store's handle of a record, which a capability slot holds,
 * and back. On the target a handle is the record's address. In host builds
 * (ERX_HOST) it is an index into the test store that stands in for the
 * records, from 1; the capability core and its tests then name objects by
 * small integers and never dereference one. Handle 0 names nothing, and so
 * does a host handle outside the test store.
 */
uint64_t	 erx_object_handle(const erx_object_t *object);
erx_object_t	*erx_object_from_handle(uint64_t handle);

#ifdef ERX_HOST
/*
 * The host's test store: handle i names records[i - 1]. The array is the
 * test's and must outlive every lookup; a later call replaces it.
 */
void		erx_object_test_store(erx_object_t *const *records,
		    uint64_t nrecords);
#endif

#endif /* ERX_OBJECT_H */
