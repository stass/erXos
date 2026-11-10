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
 * Modified by erXos: References are AES-128 identities of four words from one source per thread id (edit 17 of docs/design-runtime.md), the magic tables are keyed by all four, and a pid ref of this node is looked up in the alias registry.
 *
 * %CopyrightEnd%
 */

#ifdef HAVE_CONFIG_H
#  include "config.h"
#endif

#define ERL_BIF_UNIQUE_C__
#include "sys.h"
#include "erl_vm.h"
#include "erl_alloc.h"
#include "export.h"
#include "bif.h"
#include "erl_bif_unique.h"
#include "hash.h"
#include "erl_binary.h"

#include "erx/explicit_bzero.h"
#include "liberx/backend/api.h"
#include "erx_alias.h"
#include "erx_ref.h"

/* * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * *\
 * Reference                                                         *
\*                                                                   */

/*
 * erXos (docs/design-runtime.md, edit 17): a reference's identity is AES-128, under the
 * domain's secret key, of the source ordinal of the thread that made it and that source's
 * counter (sys/erxos/erx_ref.h), so its four words name nothing a party can guess.
 *
 * Each thread id has one source, in ref_sources[thr_id]: 0 is shared by the threads that are
 * no scheduler, under ref_shared_lock, and 1 to max_thr_id are the normal, dirty CPU and
 * dirty I/O schedulers', each used only by the scheduler whose thread id indexes it. A
 * maker indexes it at each use: a dirty scheduler's thread id takes its offset only after
 * init_scheduler_data, so a source picked there would be a normal scheduler's.
 * init_reference opens them in index order from a fresh runtime, so a source's ordinal is
 * its thread id, and deciphering a reference (erts_get_ref_numbers_thr_id) gives the thread
 * id of the thread that made it, which is how a timer's reference reaches its scheduler.
 */

static erx_ref_runtime_t ref_runtime;
static erx_ref_source_t *ref_sources;
static Uint32 max_thr_id;
static erts_mtx_t ref_shared_lock;

static void init_magic_ref_tables(void);

/*
 * The domain's reference key, from one erx_entropy_read, taken and zeroed out of the UTCB at
 * once, as erx_bytes:entropy/1's BIF does (nifs/erxos/erx_bytes_bif.c). Without it no reference
 * this runtime makes could be unguessable, so the runtime refuses to start.
 */
static void
read_ref_key(uint8_t key[ERX_REF_KEY_BYTES])
{
    uint64_t words[ERX_REF_KEY_BYTES / sizeof(uint64_t)];
    erx_utcb_t *utcb;
    unsigned int i;
    int status;

    ERTS_CT_ASSERT(ERX_REF_KEY_BYTES % sizeof(uint64_t) == 0);
    ERTS_CT_ASSERT(ERX_REF_KEY_BYTES <= ERX_ENTROPY_BYTES_MAX);
    status = erx_entropy_read(ERX_REF_KEY_BYTES);
    if (status != ERX_OK)
        erts_exit(ERTS_ERROR_EXIT, "references: no entropy for the reference key (status %d)\n",
                  status);
    utcb = erx_utcb_self();
    for (i = 0; i < ERX_REF_KEY_BYTES / sizeof(uint64_t); i++) {
        (void) erx_utcb_mr_load(utcb, i, &words[i]);
        (void) erx_utcb_mr_store(utcb, i, 0);
    }
    sys_memcpy(key, words, ERX_REF_KEY_BYTES);
    erx_explicit_bzero(words, sizeof(words));
}

static void
init_reference(void)
{
    uint8_t key[ERX_REF_KEY_BYTES];
    Uint32 i;

    max_thr_id = (Uint32) erts_no_schedulers;
    max_thr_id += (Uint32) erts_no_dirty_cpu_schedulers;
    max_thr_id += (Uint32) erts_no_dirty_io_schedulers;
    read_ref_key(key);
    erx_ref_runtime_init(&ref_runtime, key);	/* erases key */
    ref_sources = erts_alloc_permanent_cache_aligned(ERTS_ALC_T_MREF_TAB,
                                                     sizeof(*ref_sources) * (max_thr_id + 1));
    for (i = 0; i <= max_thr_id; i++)
        if (erx_ref_source_open(&ref_runtime, &ref_sources[i]) != ERX_OK
            || ref_sources[i].ordinal != i)
            erts_exit(ERTS_ABORT_EXIT, "references: no source for thread %u\n", (unsigned) i);
    erts_mtx_init(&ref_shared_lock, "ref_shared_source", NIL,
                  ERTS_LOCK_FLAGS_PROPERTY_STATIC | ERTS_LOCK_FLAGS_CATEGORY_GENERIC);
    init_magic_ref_tables();
    erx_alias_init();
}

/*
 * A source holds 2^96 counter values, which no runtime uses up (at 10^9 references a second,
 * over 10^12 years), so a spent source is a fault of the runtime, never something a party
 * can bring about, and the runtime stops rather than reuse a value: none of ERTS's reference
 * makers has a failure path (docs/design-runtime.md, "Unguessable references").
 */
static ERTS_INLINE void
make_from_source(erx_ref_source_t *source, Uint32 ref[ERTS_REF_NUMBERS])
{
    if (erx_ref_make(&ref_runtime, source, ref) != ERX_OK)
        erts_exit(ERTS_ABORT_EXIT, "references: source %u is spent\n", (unsigned) source->ordinal);
}

void
erts_sched_make_ref_in_array(ErtsSchedulerData *esdp, Uint32 ref[ERTS_REF_NUMBERS])
{
    ASSERT(esdp && esdp->thr_id >= 1 && esdp->thr_id <= max_thr_id);
    make_from_source(&ref_sources[esdp->thr_id], ref);
}

Uint32
erts_get_ref_numbers_thr_id(const Uint32 *ref)
{
    uint32_t ordinal;

    if (erx_ref_source_of(&ref_runtime, ref, &ordinal) != ERX_OK)
        return ERTS_REF_NO_THR_ID;
    ASSERT(ordinal <= max_thr_id);
    return (Uint32) ordinal;
}

static ERTS_INLINE void
make_ref_in_array(Uint32 ref[ERTS_REF_NUMBERS])
{
    ErtsSchedulerData *esdp = erts_get_scheduler_data();
    if (esdp)
	erts_sched_make_ref_in_array(esdp, ref);
    else {
        erts_mtx_lock(&ref_shared_lock);
        make_from_source(&ref_sources[0], ref);
        erts_mtx_unlock(&ref_shared_lock);
    }
}

void
erts_make_ref_in_array(Uint32 ref[ERTS_REF_NUMBERS])
{
    make_ref_in_array(ref);
}

/* A magic reference is an ordinary one whose identity its magic binary keeps. */
void
erts_make_magic_ref_in_array(Uint32 ref[ERTS_REF_NUMBERS])
{
    make_ref_in_array(ref);
}

Eterm erts_make_ref_in_buffer(Eterm buffer[ERTS_REF_THING_SIZE])
{
    Eterm* hp = buffer;
    Uint32 ref[ERTS_REF_NUMBERS];

    make_ref_in_array(ref);
    write_ref_thing(hp, ref);
    return make_internal_ref(hp);
}

Eterm erts_make_ref(Process *c_p)
{
    Eterm* hp;
    Uint32 ref[ERTS_REF_NUMBERS];

    ERTS_LC_ASSERT(ERTS_PROC_LOCK_MAIN & erts_proc_lc_my_proc_locks(c_p));

    hp = HAlloc(c_p, ERTS_REF_THING_SIZE);

    make_ref_in_array(ref);
    write_ref_thing(hp, ref);

    return make_internal_ref(hp);
}

/*
 * A pid ref: an ordinary identity with its owner's pid kept beside it on the heap. It becomes
 * an active alias, recorded in the registry, when a monitor keyed by it enters the owner's
 * monitor tree with an alias state (erx_alias.h).
 */
Eterm erts_make_pid_ref(Process *c_p)
{
    Eterm* hp;
    Uint32 ref[ERTS_REF_NUMBERS];

    ERTS_LC_ASSERT(ERTS_PROC_LOCK_MAIN & erts_proc_lc_my_proc_locks(c_p));

    hp = HAlloc(c_p, ERTS_PID_REF_THING_SIZE);

    make_ref_in_array(ref);
    write_pid_ref_thing(hp, ref, c_p->common.id);

    return make_internal_ref(hp);
}

/*
 * The pid of the active alias refn of this node, from the registry; am_undefined when refn is
 * no active alias, so the decoder makes it an ordinary reference. refn is untrusted input.
 */
Eterm
erts_pid_ref_lookup(const Uint32 *refn, int len)
{
    uint64_t owner;

    if (len != ERTS_REF_NUMBERS)
        return am_undefined;
    owner = erx_alias_owner(refn);
    return owner == 0 ? am_undefined : (Eterm) owner;
}

/*
 * Magic reference tables, keyed by a reference's four words. Identity words are uniform, so
 * the first one picks the table, whichever thread made the reference.
 */

typedef ErtsNSchedMagicRefTableEntry ErtsMagicRefTableEntry;

typedef struct {
    erts_rwmtx_t rwmtx;
    Hash hash;
    char name[32];
} ErtsMagicRefTable;

typedef struct {
    union {
	ErtsMagicRefTable table;
	char align__[ERTS_ALC_CACHE_LINE_ALIGN_SIZE(sizeof(ErtsMagicRefTable))];
    } u;
} ErtsAlignedMagicRefTable;

ErtsAlignedMagicRefTable *magic_ref_table;

static ERTS_INLINE ErtsMagicRefTable *
magic_ref_table_of(const Uint32 refn[ERTS_REF_NUMBERS])
{
    return &magic_ref_table[refn[0] % (erts_no_schedulers + 1)].u.table;
}

static ERTS_INLINE void
magic_ref_key(ErtsMagicRefTableEntry *tmpl, const Uint32 refn[ERTS_REF_NUMBERS])
{
    sys_memcpy(tmpl->num, refn, sizeof(tmpl->num));
}

ErtsMagicBinary *
erts_magic_ref_lookup_bin(const Uint32 refn[ERTS_REF_NUMBERS])
{
    ErtsMagicRefTableEntry tmpl;
    ErtsMagicRefTableEntry *tep;
    ErtsMagicBinary *mb;
    ErtsMagicRefTable *tblp = magic_ref_table_of(refn);

    magic_ref_key(&tmpl, refn);

    erts_rwmtx_rlock(&tblp->rwmtx);

    tep = (ErtsMagicRefTableEntry *) hash_get(&tblp->hash, &tmpl);
    if (!tep)
	mb = NULL;
    else {
	erts_aint_t refc;
	mb = tep->mb;
        refc = erts_refc_inc_unless(&mb->intern.refc, 0, 0);
        if (refc == 0)
            mb = NULL;
    }

    erts_rwmtx_runlock(&tblp->rwmtx);

    return mb;
}

void
erts_magic_ref_save_bin__(Eterm ref)
{
    ErtsMagicRefTableEntry tmpl;
    ErtsMagicRefTableEntry *tep;
    ErtsMRefThing *mrtp;
    ErtsMagicRefTable *tblp;
    Uint32 *refn;

    ASSERT(is_internal_magic_ref(ref));

    mrtp = (ErtsMRefThing *) internal_ref_val(ref);
    refn = mrtp->mb->refn;

    magic_ref_key(&tmpl, refn);
    tblp = magic_ref_table_of(refn);

    erts_rwmtx_rlock(&tblp->rwmtx);

    tep = (ErtsMagicRefTableEntry *) hash_get(&tblp->hash, &tmpl);

    erts_rwmtx_runlock(&tblp->rwmtx);

    if (!tep) {
	ErtsMagicRefTableEntry *used_tep;

	tep = erts_alloc(ERTS_ALC_T_MREF_NSCHED_ENT,
			 sizeof(ErtsMagicRefTableEntry));
	magic_ref_key(tep, refn);
	tep->mb = mrtp->mb;

	erts_rwmtx_rwlock(&tblp->rwmtx);

	used_tep = hash_put(&tblp->hash, tep);

	erts_rwmtx_rwunlock(&tblp->rwmtx);

	if (used_tep != tep)
	    erts_free(ERTS_ALC_T_MREF_NSCHED_ENT, (void *) tep);
    }
}

void
erts_magic_ref_remove_bin(Uint32 refn[ERTS_REF_NUMBERS])
{
    ErtsMagicRefTableEntry tmpl;
    ErtsMagicRefTableEntry *tep;
    ErtsMagicRefTable *tblp = magic_ref_table_of(refn);

    magic_ref_key(&tmpl, refn);

    erts_rwmtx_rlock(&tblp->rwmtx);

    tep = (ErtsMagicRefTableEntry *) hash_get(&tblp->hash, &tmpl);

    erts_rwmtx_runlock(&tblp->rwmtx);

    if (tep) {
	erts_rwmtx_rwlock(&tblp->rwmtx);

	tep = hash_remove(&tblp->hash, &tmpl);

	erts_rwmtx_rwunlock(&tblp->rwmtx);

	if (tep)
	    erts_free(ERTS_ALC_T_MREF_NSCHED_ENT, (void *) tep);
    }
}

static int mreft_cmp(void *ve1, void *ve2)
{
    ErtsMagicRefTableEntry *e1 = ve1;
    ErtsMagicRefTableEntry *e2 = ve2;
    return sys_memcmp(e1->num, e2->num, sizeof(e1->num)) != 0;
}

static HashValue mreft_hash(void *ve)
{
    ErtsMagicRefTableEntry *e = ve;
    return (HashValue) e->num[1];
}

static void *mreft_alloc(void *ve)
{
    /*
     * We allocate the element before
     * hash_put() and pass it as
     * template which we get as
     * input...
     */
    return ve;
}

static void mreft_free(void *ve)
{
    /*
     * We free the element ourselves
     * after hash_remove()...
     */
}

static void *mreft_meta_alloc(int i, size_t size)
{
    return erts_alloc(ERTS_ALC_T_MREF_TAB_BKTS, size);
}

static void mreft_meta_free(int i, void *ptr)
{
    erts_free(ERTS_ALC_T_MREF_TAB_BKTS, ptr);
}

static void
init_magic_ref_tables(void)
{
    HashFunctions hash_funcs;
    int i;

    magic_ref_table = erts_alloc_permanent_cache_aligned(ERTS_ALC_T_MREF_TAB,
							 (sizeof(ErtsAlignedMagicRefTable)
							  * (erts_no_schedulers + 1)));

    hash_funcs.hash = mreft_hash;
    hash_funcs.cmp = mreft_cmp;

    hash_funcs.alloc = mreft_alloc;
    hash_funcs.free = mreft_free;
    hash_funcs.meta_alloc = mreft_meta_alloc;
    hash_funcs.meta_free = mreft_meta_free;
    hash_funcs.meta_print = erts_print;

    for (i = 0; i <= erts_no_schedulers; i++) {
	ErtsMagicRefTable *tblp = &magic_ref_table[i].u.table;
	erts_snprintf(&tblp->name[0], sizeof(tblp->name),
		      "magic_ref_table_%d", i);
	hash_init(0, &tblp->hash, &tblp->name[0], 1, hash_funcs);
	erts_rwmtx_init(&tblp->rwmtx, "magic_ref_table", NIL,
        ERTS_LOCK_FLAGS_PROPERTY_STATIC | ERTS_LOCK_FLAGS_CATEGORY_GENERIC);
    }
}

void erts_ref_bin_free(ErtsMagicBinary *mb)
{
    erts_bin_free((Binary *) mb);
}

/* * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * *\
 * Unique Integer                                                    *
\*                                                                   */

static struct {
    union {
	struct {
	    int left_shift;
	    int right_shift;
	    Uint64 mask;
	    Uint64 val0_max;
	} o;
	char align__[ERTS_CACHE_LINE_SIZE];
    } r;
    union {
	erts_atomic64_t val1;
	char align__[ERTS_CACHE_LINE_SIZE];
    } w;
} unique_data erts_align_attribute(ERTS_CACHE_LINE_SIZE);

static void
init_unique_integer(void)
{
    int bits;
    unique_data.r.o.val0_max = (Uint64) erts_no_schedulers;
    unique_data.r.o.val0_max += (Uint64) erts_no_dirty_cpu_schedulers;
    unique_data.r.o.val0_max += (Uint64) erts_no_dirty_io_schedulers;
    bits = erts_fit_in_bits_int64(unique_data.r.o.val0_max);
    unique_data.r.o.left_shift = bits;
    unique_data.r.o.right_shift = 64 - bits;
    unique_data.r.o.mask = (((Uint64) 1) << bits) - 1;
    erts_atomic64_init_nob(&unique_data.w.val1, -1);
}

#define ERTS_MAX_UNIQUE_INT_HEAP_SIZE ERTS_UINT64_ARRAY_TO_BIG_MAX_HEAP_SZ(2)

static ERTS_INLINE Eterm
bld_unique_integer_term(Eterm **hpp, Uint *szp,
			Uint64 val0, Uint64 val1,
			int positive)
{
    Uint hsz;
    Uint64 unique_val[2];

    unique_val[0] = ((Uint64) val0);
    unique_val[0] |= ((Uint64) val1) << unique_data.r.o.left_shift;
    unique_val[1] = ((Uint64) val1) >> unique_data.r.o.right_shift;
    unique_val[1] &= unique_data.r.o.mask;

    if (positive) {
	unique_val[0]++;
	if (unique_val[0] == 0)
	    unique_val[1]++;
    }
    else {
	ASSERT(MIN_SMALL < 0);
	if (unique_val[1] == 0
	    && unique_val[0] < ((Uint64) -1*((Sint64) MIN_SMALL))) {
	    Sint64 s_unique_val = (Sint64) unique_val[0];
	    s_unique_val += MIN_SMALL;
	    ASSERT(MIN_SMALL <= s_unique_val && s_unique_val < 0);
	    if (szp)
		*szp = 0;
	    if (!hpp)
		return THE_NON_VALUE;
	    return make_small((Sint) s_unique_val);
	}
	if (unique_val[0] < ((Uint64) -1*((Sint64) MIN_SMALL))) {
	    ASSERT(unique_val[1] != 0);
	    unique_val[1] -= 1;
	}
	unique_val[0] += MIN_SMALL;
    }

    if (!unique_val[1]) {
	if (unique_val[0] <= MAX_SMALL) {
	    if (szp)
		*szp = 0;
	    if (!hpp)
		return THE_NON_VALUE;
	    return make_small((Uint) unique_val[0]);
	}

	if (szp)
	    *szp = ERTS_UINT64_HEAP_SIZE(unique_val[0]);
	if (!hpp)
	    return THE_NON_VALUE;
	return erts_uint64_to_big(unique_val[0], hpp);
    }
    else {
	Eterm tmp, *tmp_hp, res;
	DeclareTmpHeapNoproc(local_heap, 2*ERTS_MAX_UNIQUE_INT_HEAP_SIZE);

	UseTmpHeapNoproc(2*ERTS_MAX_UNIQUE_INT_HEAP_SIZE);

	tmp_hp = local_heap;

	tmp = erts_uint64_array_to_big(&tmp_hp, 0, 2, unique_val);
	ASSERT(is_big(tmp));

	hsz = big_arity(tmp) + 1;

	ASSERT(hsz <= ERTS_MAX_UNIQUE_INT_HEAP_SIZE);

	if (szp)
	    *szp = hsz;

	if (!hpp)
	    res = THE_NON_VALUE;
	else {
	    int hix;
	    Eterm *hp = *hpp;
            ASSERT(hp != NULL);
	    tmp_hp = big_val(tmp);
	    for (hix = 0; hix < hsz; hix++)
		hp[hix] = tmp_hp[hix];

	    *hpp = hp + hsz;
	    res = make_big(hp);
	}

	UnUseTmpHeapNoproc(2*ERTS_MAX_UNIQUE_INT_HEAP_SIZE);

	return res;
    }
}

static ERTS_INLINE Eterm unique_integer_bif(Process *c_p, int positive)
{
    ErtsSchedulerData *esdp;
    Uint64 thr_id, unique;
    Uint hsz;
    Eterm *hp;

    esdp = erts_proc_sched_data(c_p);
    thr_id = (Uint64) esdp->thr_id;
    unique = esdp->unique++;
    bld_unique_integer_term(NULL, &hsz, thr_id, unique, positive);
    hp = hsz ? HAlloc(c_p, hsz) : NULL;
    return bld_unique_integer_term(&hp, NULL, thr_id, unique, positive);
}

Uint
erts_raw_unique_integer_heap_size(Uint64 val[ERTS_UNIQUE_INT_RAW_VALUES],
                                  int positive)
{
    Uint sz;
    bld_unique_integer_term(NULL, &sz, val[0], val[1], positive);
    return sz;
}

Eterm
erts_raw_make_unique_integer(Eterm **hpp, Uint64 val[ERTS_UNIQUE_INT_RAW_VALUES],
    int positive)
{
    return bld_unique_integer_term(hpp, NULL, val[0], val[1], positive);
}

void
erts_raw_get_unique_integer(Uint64 val[ERTS_UNIQUE_INT_RAW_VALUES])
{
    ErtsSchedulerData *esdp = erts_get_scheduler_data();
    if (esdp) {
	val[0] = (Uint64) esdp->thr_id;
	val[1] = esdp->unique++;
    }
    else {
	val[0] = (Uint64) 0;
	val[1] = (Uint64) erts_atomic64_inc_read_nob(&unique_data.w.val1);
    }
}


Sint64
erts_get_min_unique_integer(void)
{
    return (Sint64) MIN_SMALL;
}

/* --- Debug --- */

Eterm
erts_debug_make_unique_integer(Process *c_p, Eterm etval0, Eterm etval1)
{
    Uint64 val0, val1;
    Uint hsz;
    Eterm res, *hp, *end_hp;

    if (!term_to_Uint64(etval0, &val0))
	return THE_NON_VALUE;

    if (!term_to_Uint64(etval1, &val1))
	return THE_NON_VALUE;

    bld_unique_integer_term(NULL, &hsz, val0, val1, 0);

    hp = HAlloc(c_p, hsz);
    end_hp = hp + hsz;

    res = bld_unique_integer_term(&hp, NULL, val0, val1, 0);
    if (hp != end_hp)
	ERTS_INTERNAL_ERROR("Heap allocation error");

    return res;
}

/* * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * *\
 * Strict Monotonic Counter                                          *
\*                                                                   */

static struct {
    union {
	erts_atomic64_t value;
	char align__[ERTS_CACHE_LINE_SIZE];
    } w;
} raw_unique_monotonic_integer erts_align_attribute(ERTS_CACHE_LINE_SIZE);

#if defined(ARCH_32)
#  define ERTS_UNIQUE_MONOTONIC_OFFSET ERTS_SINT64_MIN
#else
#  define ERTS_UNIQUE_MONOTONIC_OFFSET MIN_SMALL
#endif

static void
init_unique_monotonic_integer(void)
{
    erts_atomic64_init_nob(&raw_unique_monotonic_integer.w.value,
			   (erts_aint64_t) -1);
}

static ERTS_INLINE Uint64
get_raw_unique_monotonic_integer(void)
{
    return (Uint64) erts_atomic64_inc_read_mb(&raw_unique_monotonic_integer.w.value);
}

static ERTS_INLINE Uint
get_unique_monotonic_integer_heap_size(Uint64 raw, int positive)
{
    if (positive) {
	Uint64 value = raw+1;
	return ERTS_UINT64_HEAP_SIZE(value);
    }
    else {
	Sint64 value = ((Sint64) raw) + ERTS_UNIQUE_MONOTONIC_OFFSET;
	if (IS_SSMALL(value))
	    return 0;
#if defined(ARCH_32)
	return ERTS_SINT64_HEAP_SIZE(value);
#else
	return ERTS_UINT64_HEAP_SIZE((Uint64) value);
#endif
    }
}

static ERTS_INLINE Eterm
make_unique_monotonic_integer_value(Eterm *hp, Uint hsz, Uint64 raw, int positive)
{
    Eterm res;
#ifdef DEBUG
    Eterm *end_hp = hp + hsz;
#endif

    if (positive) {
	Uint64 value = raw+1;
	res = hsz ? erts_uint64_to_big(value, &hp) : make_small(value);
    }
    else {
	Sint64 value = ((Sint64) raw) + ERTS_UNIQUE_MONOTONIC_OFFSET;
	if (hsz == 0)
	    res = make_small(value);
	else {
#if defined(ARCH_32)
	    res = erts_sint64_to_big(value, &hp);
#else 
	    res = erts_uint64_to_big((Uint64) value, &hp);
#endif
	}
    }

    ASSERT(end_hp == hp);

    return res;
}

static ERTS_INLINE Eterm
unique_monotonic_integer_bif(Process *c_p, int positive)
{
    Uint64 raw;
    Uint hsz;
    Eterm *hp;

    raw = get_raw_unique_monotonic_integer();
    hsz = get_unique_monotonic_integer_heap_size(raw, positive);
    hp = hsz ? HAlloc(c_p, hsz) : NULL;
    return make_unique_monotonic_integer_value(hp, hsz, raw, positive);
}

Sint64
erts_raw_get_unique_monotonic_integer(void)
{
    return get_raw_unique_monotonic_integer();
}

Uint
erts_raw_unique_monotonic_integer_heap_size(Sint64 raw, int positive)
{
    return get_unique_monotonic_integer_heap_size(raw, positive);
}

Eterm
erts_raw_make_unique_monotonic_integer_value(Eterm **hpp, Sint64 raw, int positive)
{
    Uint hsz = get_unique_monotonic_integer_heap_size(raw, positive);
    Eterm res = make_unique_monotonic_integer_value(*hpp, hsz, raw, positive);
    *hpp += hsz;
    return res;
}

Sint64
erts_get_min_unique_monotonic_integer(void)
{
    return ERTS_UNIQUE_MONOTONIC_OFFSET;
}

/* --- Debug --- */

int
erts_debug_set_unique_monotonic_integer_state(Eterm et_value)
{
    Sint64 value;

    if (!term_to_Sint64(et_value, &value)) {
	Uint64 uvalue;
	if (!term_to_Uint64(et_value, &uvalue))
	    return 0;
	value = (Sint64) uvalue;
    }

    erts_atomic64_set_mb(&raw_unique_monotonic_integer.w.value,
			 (erts_aint64_t) value);
    return 1;
}

Eterm
erts_debug_get_unique_monotonic_integer_state(Process *c_p)
{
    Uint64 value;
    Eterm hsz, *hp;

    value = (Uint64) erts_atomic64_read_mb(&raw_unique_monotonic_integer.w.value);

    if (IS_USMALL(0, value))
	return make_small(value);
    hsz = ERTS_UINT64_HEAP_SIZE(value);
    hp = HAlloc(c_p, hsz);
    return erts_uint64_to_big(value, &hp);
}

/* * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * *\
 * Initilazation                                                     *
\*                                                                   */

void
erts_bif_unique_init(void)
{
    init_reference();
    init_unique_monotonic_integer();
    init_unique_integer();
}

void
erts_sched_bif_unique_init(ErtsSchedulerData *esdp)
{
    esdp->unique = (Uint64) 0;
}

/* * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * *\
 * The BIFs                                                          *
\*                                                                   */


BIF_RETTYPE make_ref_0(BIF_ALIST_0)
{
    BIF_RETTYPE res;
    Eterm* hp;

    ERTS_LC_ASSERT(ERTS_PROC_LOCK_MAIN & erts_proc_lc_my_proc_locks(BIF_P));

    hp = HAlloc(BIF_P, ERTS_REF_THING_SIZE);

    res = erts_sched_make_ref_in_buffer(erts_proc_sched_data(BIF_P), hp);

    BIF_RET(res);
}

BIF_RETTYPE unique_integer_0(BIF_ALIST_0)
{
    BIF_RET(unique_integer_bif(BIF_P, 0));
}

BIF_RETTYPE unique_integer_1(BIF_ALIST_1)
{
    Eterm modlist = BIF_ARG_1;
    int monotonic = 0;
    int positive = 0;
    BIF_RETTYPE res;

    while (is_list(modlist)) {
	Eterm *consp = list_val(modlist);
	switch (CAR(consp)) {
	case am_monotonic:
	    monotonic = 1;
	    break;
	case am_positive:
	    positive = 1;
	    break;
	default:
	    BIF_ERROR(BIF_P, BADARG);
	}
	modlist = CDR(consp);
    }

    if (is_not_nil(modlist))
	BIF_ERROR(BIF_P, BADARG);

    if (monotonic)
	res = unique_monotonic_integer_bif(BIF_P, positive);
    else
	res = unique_integer_bif(BIF_P, positive);

    BIF_RET(res);
}
