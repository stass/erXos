/*
 * %CopyrightBegin%
 *
 * SPDX-License-Identifier: Apache-2.0
 *
 * Copyright Ericsson AB 2014-2025. All Rights Reserved.
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 *
 * Modified by erXos: A reference's four words carry no thread id and no kind bits (edit 17 of docs/design-runtime.md); the thread id is deciphered, and pid ref and magic lookups are functions of erl_bif_unique.c.
 *
 * %CopyrightEnd%
 */

#ifndef ERTS_BIF_UNIQUE_H__
#define ERTS_BIF_UNIQUE_H__

#include "erl_term.h"
#include "erl_process.h"
#include "big.h"
#define ERTS_BINARY_TYPES_ONLY__
#include "erl_binary.h"
#undef ERTS_BINARY_TYPES_ONLY__

void erts_bif_unique_init(void);
void erts_sched_bif_unique_init(ErtsSchedulerData *esdp);

/* reference */
Eterm erts_make_ref(Process *);
Eterm erts_make_pid_ref(Process *);
Eterm erts_make_ref_in_buffer(Eterm buffer[ERTS_REF_THING_SIZE]);
void erts_make_ref_in_array(Uint32 ref[ERTS_REF_NUMBERS]);
void erts_make_magic_ref_in_array(Uint32 ref[ERTS_REF_NUMBERS]);
void erts_magic_ref_remove_bin(Uint32 refn[ERTS_REF_NUMBERS]);
void erts_magic_ref_save_bin__(Eterm ref);


/* strict monotonic counter */

#define ERTS_MAX_UNIQUE_MONOTONIC_INTEGER_HEAP_SIZE ERTS_MAX_UINT64_HEAP_SIZE

/*
 * Note that a raw value is an intermediate value that 
 * not necessarily correspond to the end result.
 */
Sint64 erts_raw_get_unique_monotonic_integer(void);
Uint erts_raw_unique_monotonic_integer_heap_size(Sint64 raw, int positive);
Eterm erts_raw_make_unique_monotonic_integer_value(Eterm **hpp, Sint64 raw,
                                                   int positive);

Sint64 erts_get_min_unique_monotonic_integer(void);

int erts_debug_set_unique_monotonic_integer_state(Eterm et_value);
Eterm erts_debug_get_unique_monotonic_integer_state(Process *c_p);

/* unique integer */
#define ERTS_UNIQUE_INT_RAW_VALUES 2
#define ERTS_MAX_UNIQUE_INT_HEAP_SIZE ERTS_UINT64_ARRAY_TO_BIG_MAX_HEAP_SZ(2)

Uint erts_raw_unique_integer_heap_size(Uint64 val[ERTS_UNIQUE_INT_RAW_VALUES],
                                       int positive);
Eterm erts_raw_make_unique_integer(Eterm **hpp,
                                   Uint64 val[ERTS_UNIQUE_INT_RAW_VALUES],
                                   int postive);
void erts_raw_get_unique_integer(Uint64 val[ERTS_UNIQUE_INT_RAW_VALUES]);
Sint64 erts_get_min_unique_integer(void);

Eterm erts_debug_make_unique_integer(Process *c_p,
				     Eterm etval0,
				     Eterm etval1);


/*
 * erXos (docs/design-runtime.md, edit 17): an identity carries no thread id and no kind bit.
 * The thread id of the thread that made a reference is deciphered from its words, and is
 * ERTS_REF_NO_THR_ID for words no thread of this runtime enciphered; stock's range checks on
 * a thread id (no scheduler has ~0) then refuse them.
 */
#define ERTS_REF_NO_THR_ID (~((Uint32) 0))

void erts_sched_make_ref_in_array(ErtsSchedulerData *esdp, Uint32 ref[ERTS_REF_NUMBERS]);
Uint32 erts_get_ref_numbers_thr_id(const Uint32 *ref);
ErtsMagicBinary *erts_magic_ref_lookup_bin(const Uint32 ref[ERTS_REF_NUMBERS]);
Eterm erts_pid_ref_lookup(const Uint32 *refn, int len);

ERTS_GLB_INLINE void erts_sched_make_magic_ref_in_array(ErtsSchedulerData *esdp,
							Uint32 ref[ERTS_REF_NUMBERS]);
ERTS_GLB_INLINE Eterm erts_sched_make_ref_in_buffer(ErtsSchedulerData *esdp,
						    Eterm buffer[ERTS_REF_THING_SIZE]);
ERTS_GLB_INLINE Eterm erts_mk_magic_ref_get_refc(Eterm * *hpp, ErlOffHeap * ohp, Binary*, erts_aint_t*);
ERTS_GLB_INLINE Eterm erts_mk_magic_ref(Eterm **hpp, ErlOffHeap *ohp, Binary *mbp);
ERTS_GLB_INLINE Binary *erts_magic_ref2bin(Eterm mref);
ERTS_GLB_INLINE void erts_magic_ref_save_bin(Eterm ref);
ERTS_GLB_INLINE Eterm erts_get_pid_of_ref(Eterm ref);

#if ERTS_GLB_INLINE_INCL_FUNC_DEF

/* A magic reference is an ordinary one; its kind is in its thing, not its identity. */
ERTS_GLB_INLINE void
erts_sched_make_magic_ref_in_array(ErtsSchedulerData *esdp,
				   Uint32 ref[ERTS_REF_NUMBERS])
{
    erts_sched_make_ref_in_array(esdp, ref);
}

ERTS_GLB_INLINE Eterm
erts_sched_make_ref_in_buffer(ErtsSchedulerData *esdp,
			      Eterm buffer[ERTS_REF_THING_SIZE])
{
    Eterm* hp = buffer;
    Uint32 ref[ERTS_REF_NUMBERS];

    erts_sched_make_ref_in_array(esdp, ref);
    write_ref_thing(hp, ref);
    return make_internal_ref(hp);
}

ERTS_GLB_INLINE Eterm
erts_mk_magic_ref_get_refc(Eterm **hpp, ErlOffHeap *ohp, Binary *bp, erts_aint_t* refcp)
{
    Eterm *hp = *hpp;
    ASSERT(bp->intern.flags & BIN_FLAG_MAGIC);
    write_magic_ref_thing(hp, ohp, (ErtsMagicBinary *) bp);
    *hpp += ERTS_MAGIC_REF_THING_SIZE;
    if (refcp)
        *refcp = erts_refc_inctest(&bp->intern.refc, 1);
    else
        erts_refc_inc(&bp->intern.refc, 1);
    OH_OVERHEAD(ohp, bp->orig_size / sizeof(Eterm));
    return make_internal_ref(hp);
}

ERTS_GLB_INLINE Eterm
erts_mk_magic_ref(Eterm **hpp, ErlOffHeap *ohp, Binary *bp)
{
    return erts_mk_magic_ref_get_refc(hpp, ohp, bp, NULL);
}

ERTS_GLB_INLINE Binary *
erts_magic_ref2bin(Eterm mref)
{
    ErtsMRefThing *mrtp;
    ASSERT(is_internal_magic_ref(mref));
    mrtp = (ErtsMRefThing *) internal_ref_val(mref);
    return (Binary *) mrtp->mb;
}

/*
 * Save the magic binary of a ref when the
 * ref is exposed to the outside world...
 */
ERTS_GLB_INLINE void
erts_magic_ref_save_bin(Eterm ref)
{
    if (is_internal_magic_ref(ref))
	erts_magic_ref_save_bin__(ref);
}

ERTS_GLB_INLINE Eterm erts_get_pid_of_ref(Eterm ref)
{
    if (is_internal_pid_ref(ref))
        return pid_ref_thing_get_pid(internal_ref_val(ref));
    if (is_ref(ref))
        return am_undefined;
    return THE_NON_VALUE;
}


#endif /* ERTS_GLB_INLINE_INCL_FUNC_DEF */


/*
 * Storage of internal refs in misc structures...
 */

#include "erl_message.h"

#if ERTS_REF_NUMBERS != 4 || ERTS_PID_REF_NUMBERS != 6
#  error fix this...
#endif

ERTS_GLB_INLINE int erts_internal_ref_number_cmp(const Uint32 *num1, const Uint32 *num2);

#if ERTS_GLB_INLINE_INCL_FUNC_DEF

/* Identities compare most significant word first, the last word the most significant. */
ERTS_GLB_INLINE int
erts_internal_ref_number_cmp(const Uint32 *num1,
			     const Uint32 *num2)
{
    int i;

    for (i = ERTS_REF_NUMBERS - 1; i >= 0; i--)
	if (num1[i] != num2[i])
	    return num1[i] > num2[i] ? 1 : -1;
    return 0;
}

#endif /* #if ERTS_GLB_INLINE_INCL_FUNC_DEF */

/* Iref storage for all internal references... */ 
typedef struct {
    Uint16 is_magic;
    Uint16 is_pid_ref;
    union {
	ErtsMagicBinary *mb;
	Uint32 num[ERTS_MAX_INTERNAL_REF_NUMBERS];
    } u;
} ErtsIRefStorage;

void erts_ref_bin_free(ErtsMagicBinary *mb);

ERTS_GLB_INLINE void erts_iref_storage_save(ErtsIRefStorage *iref, Eterm ref);
ERTS_GLB_INLINE void erts_iref_storage_clean(ErtsIRefStorage *iref);
ERTS_GLB_INLINE Uint erts_iref_storage_heap_size(ErtsIRefStorage *iref);
ERTS_GLB_INLINE Eterm erts_iref_storage_make_ref(ErtsIRefStorage *iref,
						 Eterm **hpp, ErlOffHeap *ohp,
						 int clean_storage);
ERTS_GLB_INLINE int erts_iref_storage_cmp(ErtsIRefStorage *iref1,
					  ErtsIRefStorage *iref2);


#if ERTS_GLB_INLINE_INCL_FUNC_DEF

ERTS_GLB_INLINE void
erts_iref_storage_save(ErtsIRefStorage *iref, Eterm ref)
{
    Eterm *hp;

    ASSERT(is_internal_ref(ref));

    hp = boxed_val(ref);

    iref->is_magic = 0;
    iref->is_pid_ref = 0;
    if (is_ordinary_ref_thing(hp)) {
	ErtsORefThing *rtp = (ErtsORefThing *) hp;
	sys_memcpy(iref->u.num, rtp->num, ERTS_REF_NUMBERS * sizeof(Uint32));
    }
    else if (is_pid_ref_thing(hp)) {
	ErtsPRefThing *prtp = (ErtsPRefThing *) hp;
	iref->is_pid_ref = 1;
	sys_memcpy(iref->u.num, prtp->num, ERTS_PID_REF_NUMBERS * sizeof(Uint32));
    }
    else {
	ErtsMRefThing *mrtp = (ErtsMRefThing *) hp;
	ASSERT(is_magic_ref_thing(hp));
	iref->is_magic = 1;
	iref->u.mb = mrtp->mb;
	erts_refc_inc(&mrtp->mb->intern.refc, 2);
    }
}

ERTS_GLB_INLINE void
erts_iref_storage_clean(ErtsIRefStorage *iref)
{
    if (iref->is_magic && erts_refc_dectest(&iref->u.mb->intern.refc, 0) == 0)
	erts_ref_bin_free(iref->u.mb);
#ifdef DEBUG
    sys_memset((void *) iref, 0xf, sizeof(ErtsIRefStorage));
#endif
}

ERTS_GLB_INLINE Uint
erts_iref_storage_heap_size(ErtsIRefStorage *iref)
{
    if (iref->is_magic)
        return ERTS_MAGIC_REF_THING_SIZE;
    if (iref->is_pid_ref)
        return ERTS_PID_REF_THING_SIZE;
    return ERTS_REF_THING_SIZE;
}

ERTS_GLB_INLINE Eterm
erts_iref_storage_make_ref(ErtsIRefStorage *iref,
			   Eterm **hpp, ErlOffHeap *ohp,
			   int clean_storage)
{
    Eterm *hp = *hpp;
    if (!iref->is_magic && !iref->is_pid_ref) {
	write_ref_thing(hp, iref->u.num);
	*hpp += ERTS_REF_THING_SIZE;
    }
    else if (iref->is_pid_ref) {
        Eterm pid = ((Eterm) iref->u.num[ERTS_REF_NUMBERS])
            | (((Eterm) iref->u.num[ERTS_REF_NUMBERS + 1]) << 32);
	write_pid_ref_thing(hp, iref->u.num, pid);
	*hpp += ERTS_PID_REF_THING_SIZE;        
    }
    else {
	write_magic_ref_thing(hp, ohp, iref->u.mb);
        OH_OVERHEAD(ohp, iref->u.mb->orig_size / sizeof(Eterm));
	*hpp += ERTS_MAGIC_REF_THING_SIZE;
	/*
	 * If we clean storage, the term inherits the
	 * refc increment of the cleaned storage...
	 */
	if (!clean_storage)
	    erts_refc_inc(&iref->u.mb->intern.refc, 2);
    }

#ifdef DEBUG
    if (clean_storage)
	sys_memset((void *) iref, 0xf, sizeof(ErtsIRefStorage));
#endif

    return make_internal_ref(hp);
}

ERTS_GLB_INLINE int
erts_iref_storage_cmp(ErtsIRefStorage *iref1,
		      ErtsIRefStorage *iref2)
{
    Uint32 *num1 = iref1->is_magic ? iref1->u.mb->refn : iref1->u.num;
    Uint32 *num2 = iref2->is_magic ? iref2->u.mb->refn : iref2->u.num;
    return erts_internal_ref_number_cmp(num1, num2);
}

#endif /* #if ERTS_GLB_INLINE_INCL_FUNC_DEF */


/* OIref storage for ordinary internal references only... */ 
typedef struct {
    Uint32 num[ERTS_REF_NUMBERS];
} ErtsOIRefStorage;

ERTS_GLB_INLINE void erts_oiref_storage_save(ErtsOIRefStorage *oiref,
					     Eterm ref);
ERTS_GLB_INLINE Eterm erts_oiref_storage_make_ref(ErtsOIRefStorage *oiref,
						  Eterm **hpp);
ERTS_GLB_INLINE int erts_oiref_storage_cmp(ErtsOIRefStorage *oiref1,
					   ErtsOIRefStorage *oiref2);

#if ERTS_GLB_INLINE_INCL_FUNC_DEF

ERTS_GLB_INLINE void
erts_oiref_storage_save(ErtsOIRefStorage *oiref, Eterm ref)
{
    ErtsORefThing *rtp;
    ASSERT(is_internal_ordinary_ref(ref));

    rtp = (ErtsORefThing *) internal_ref_val(ref);
    sys_memcpy(oiref->num, rtp->num, sizeof(oiref->num));
}

ERTS_GLB_INLINE Eterm
erts_oiref_storage_make_ref(ErtsOIRefStorage *oiref, Eterm **hpp)
{
    Eterm *hp = *hpp;
    write_ref_thing(hp, oiref->num);
    *hpp += ERTS_REF_THING_SIZE;
    return make_internal_ref(hp);
}

ERTS_GLB_INLINE int
erts_oiref_storage_cmp(ErtsOIRefStorage *oiref1,
		       ErtsOIRefStorage *oiref2)
{
    return erts_internal_ref_number_cmp(oiref1->num, oiref2->num);
}

#endif /* #if ERTS_GLB_INLINE_INCL_FUNC_DEF */


ERTS_GLB_INLINE Eterm
erts_proc_store_ref(Process *c_p, Uint32 *ref);

#if ERTS_GLB_INLINE_INCL_FUNC_DEF

ERTS_GLB_INLINE Eterm
erts_proc_store_ref(Process *c_p, Uint32 *ref)
{
    Eterm *hp = HAlloc(c_p, (Sint)ERTS_REF_THING_SIZE);
    write_ref_thing(hp, ref);
    return make_internal_ref(hp);
}

#endif

#endif /*  ERTS_BIF_UNIQUE_H__ */

#if (defined(ERTS_ALLOC_C__) || defined(ERL_BIF_UNIQUE_C__)) \
    && !defined(ERTS_BIF_UNIQUE_H__FIX_ALLOC_TYPES__)
#define ERTS_BIF_UNIQUE_H__FIX_ALLOC_TYPES__

#include "hash.h"

/* A magic reference table's entry, keyed by the reference's identity. */
typedef struct {
    HashBucket hash;
    ErtsMagicBinary *mb;
    Uint32 num[ERTS_REF_NUMBERS];
} ErtsNSchedMagicRefTableEntry;

typedef struct {
    HashBucket hash;
    Eterm pid;
    Uint64 value;
} ErtsNSchedPidRefTableEntry;

#endif
