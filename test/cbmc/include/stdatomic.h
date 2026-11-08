/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

#ifndef ERX_CBMC_STDATOMIC_H
#define ERX_CBMC_STDATOMIC_H

/*
 * The <stdatomic.h> CBMC harnesses build with, ahead of the host's on the
 * include path. The host's header (clang's, on macOS) spells the
 * operations as clang's __c11_atomic_* builtins, which CBMC does not
 * know: it would treat each load as an unknown function returning any
 * value and each store as doing nothing, and check nothing real. This
 * header maps the operations the cores use onto GCC's __atomic builtins,
 * which CBMC models. An operation it does not map stays undeclared, and
 * the runner fails a harness whose run reports an undeclared function.
 *
 * The model is an assumption every report lists: the harnesses run one
 * thread, and CBMC treats each access as indivisible and sequentially
 * consistent. It accepts the memory order and ignores it, so a weakened
 * order is not a defect these harnesses can find; ordering belongs to
 * herd7 and the
 * conformance tests (docs/design-verification.md).
 */

typedef enum memory_order {
	memory_order_relaxed = __ATOMIC_RELAXED,
	memory_order_consume = __ATOMIC_CONSUME,
	memory_order_acquire = __ATOMIC_ACQUIRE,
	memory_order_release = __ATOMIC_RELEASE,
	memory_order_acq_rel = __ATOMIC_ACQ_REL,
	memory_order_seq_cst = __ATOMIC_SEQ_CST
} memory_order;

#define atomic_load_explicit(object, order) __atomic_load_n((object), (order))
#define atomic_store_explicit(object, value, order) \
	__atomic_store_n((object), (value), (order))
#define atomic_load(object) \
	atomic_load_explicit((object), memory_order_seq_cst)
#define atomic_store(object, value) \
	atomic_store_explicit((object), (value), memory_order_seq_cst)
#define atomic_init(object, value) \
	atomic_store_explicit((object), (value), memory_order_relaxed)
#define atomic_exchange_explicit(object, value, order) \
	__atomic_exchange_n((object), (value), (order))
#define atomic_compare_exchange_strong_explicit(object, expected, desired, \
	    success, failure) \
	__atomic_compare_exchange_n((object), (expected), (desired), 0, \
	    (success), (failure))
#define atomic_fetch_add_explicit(object, operand, order) \
	__atomic_fetch_add((object), (operand), (order))
#define atomic_fetch_sub_explicit(object, operand, order) \
	__atomic_fetch_sub((object), (operand), (order))

#endif /* ERX_CBMC_STDATOMIC_H */
