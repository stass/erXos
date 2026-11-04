/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

/*
 * The IRQ objects' and the ready ring's row. function_api_irq_cases is what both
 * backends pass. function_api_hosted_irq_cases adds what holds only where an object
 * fires in the caller's thread, each fire counted, with no lines to bind
 * (docs/design-stopgap.md, "The hosted backend").
 */

#include <stdatomic.h>
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#include "erx/abi.h"
#include "liberx/backend/api.h"
#include "test/guest/function_api/cases.h"

#define LABEL_A	UINT64_C(0xa11ce)
#define LABEL_B	UINT64_C(0xb0b)
/* The space's one group is what a bind names. */
#define GROUP	function_api_group()
#define IRQ_ROUNDS 2000u

static _Atomic uint32_t helper_ok;
static _Atomic uint32_t helper_turn;
static uint64_t helper_irq;

static uint64_t
word_addr(const _Atomic uint32_t *word)
{
	return ((uint64_t)(uintptr_t)word);
}

static uint64_t
label_at(uint32_t index)
{
	return (atomic_load(&erx_utcb_self()->mr[index]));
}

/* Only software's objects here, and every handle checked. */
static bool
case_irq_refusals(void)
{
	uint64_t irq;

	return (erx_irq_create(0, 0, ERX_IRQ_MSI, 0, &irq) == ERX_ENOTSUP &&
	    erx_irq_create(0, 0, 77, 0, &irq) == ERX_EINVAL &&
	    erx_irq_bind(0, GROUP, LABEL_A) == ERX_EINVAL && erx_irq_trigger(0) == ERX_EINVAL &&
	    erx_irq_ack(UINT64_C(1) << 40) == ERX_EINVAL && erx_group_take_ready(1) == ERX_ETYPE);
}

static bool
case_irq_line_refused(void)
{
	uint64_t irq;

	return (erx_irq_create(0, 0, ERX_IRQ_LINE, 0, &irq) == ERX_ENOTSUP);
}

/* A label comes once however often its object fired; each fire moves the epoch; rebinding moves the label. */
static void
ready_once_helper(uint64_t arg)
{
	const uint64_t irq_a = arg;
	const erx_group_stat_t *const status = erx_group_status();
	const uint64_t epoch = atomic_load(&status->epoch);
	uint64_t irq_b;
	bool ok;

	ok = erx_irq_create(0, 0, ERX_IRQ_SOFT, 0, &irq_b) == ERX_OK && erx_irq_bind(irq_b, GROUP, LABEL_B) == ERX_OK;
	ok = ok && erx_group_take_ready(ERX_MSG_WORDS) == 0;
	ok = ok && erx_irq_trigger(irq_a) == ERX_OK && erx_irq_trigger(irq_b) == ERX_OK && erx_irq_trigger(irq_a) == ERX_OK;
	ok = ok && atomic_load(&status->epoch) >= epoch + 3 && atomic_load(&status->ready) == 2;
	ok = ok && erx_group_take_ready(1) == 1 && label_at(0) == LABEL_A;
	ok = ok && erx_group_take_ready(UINT32_MAX) == 1 && label_at(0) == LABEL_B;
	ok = ok && erx_group_take_ready(ERX_MSG_WORDS) == 0 && atomic_load(&status->ready) == 0;
	ok = ok && erx_irq_ack(irq_a) == ERX_OK;
	/* Free to fire again; bound again, under the new label; unbound, it delivers nothing. */
	ok = ok && erx_irq_bind(irq_b, GROUP, LABEL_A + 1) == ERX_OK && erx_irq_trigger(irq_b) == ERX_OK;
	ok = ok && erx_group_take_ready(1) == 1 && label_at(0) == LABEL_A + 1;
	ok = ok && erx_irq_bind(irq_b, ERX_CAP_NULL, 0) == ERX_OK && erx_irq_trigger(irq_b) == ERX_OK;
	ok = ok && erx_group_take_ready(1) == 0;
	atomic_store(&helper_ok, ok ? 1 : 0);
	function_api_bump_done();
	erx_thread_exit();
}

static bool
case_irq_ready_once(void)
{
	uint64_t irq;

	atomic_store(&function_api_done, 0);
	if (erx_irq_create(0, 0, ERX_IRQ_SOFT, 0, &irq) != ERX_OK || erx_irq_bind(irq, GROUP, LABEL_A) != ERX_OK ||
	    function_api_spawn_executor(ready_once_helper, irq) != ERX_OK ||
	    !function_api_wait_for(&function_api_done, 1))
		return (false);
	return (atomic_load(&helper_ok) == 1);
}

/* An executor's loop on the readiness interface: each round's trigger wakes it, and its label says why. */
static void
irq_wakes_helper(uint64_t arg)
{
	const uint32_t slot = erx_executor_slot();
	bool ok = true;

	(void)arg;
	for (uint32_t round = 1; round <= IRQ_ROUNDS && ok; round++) {
		const uint64_t epoch = atomic_load_explicit(&erx_group_status()->epoch, memory_order_acquire);
		const uint64_t own = atomic_load_explicit(&erx_group_status()->exec[slot].epoch, memory_order_acquire);
		const int taken = erx_group_take_ready(ERX_MSG_WORDS);

		if (taken == 0) {
			ok = erx_park(epoch, own, ERX_WAIT_FOREVER) == ERX_OK;
			round--;
			continue;
		}
		ok = taken == 1 && label_at(0) == LABEL_A;
		atomic_store_explicit(&helper_turn, round, memory_order_release);
		(void)erx_umtx_wake(word_addr(&helper_turn), 1);
	}
	atomic_store(&helper_ok, ok ? 1 : 0);
	function_api_bump_done();
	erx_thread_exit();
}

/* A worker fires and waits for the turn: one lost wake stops the pair until the patience runs out. */
static bool
case_irq_wakes_parked(void)
{
	atomic_store(&function_api_done, 0);
	atomic_store(&helper_ok, 0);
	if (erx_irq_create(0, 0, ERX_IRQ_SOFT, 0, &helper_irq) != ERX_OK ||
	    erx_irq_bind(helper_irq, GROUP, LABEL_A) != ERX_OK ||
	    function_api_spawn_executor(irq_wakes_helper, 0) != ERX_OK)
		return (false);
	for (uint32_t round = 1; round <= IRQ_ROUNDS; round++) {
		if (erx_irq_trigger(helper_irq) != ERX_OK || !function_api_wait_for(&helper_turn, round))
			return (false);
	}
	return (function_api_wait_for(&function_api_done, 1) && atomic_load(&helper_ok) == 1);
}

/* Objects run out as threads do. */
static bool
case_irq_objects_run_out(void)
{
	uint64_t irq;
	uint32_t made = 0;
	int status;

	while ((status = erx_irq_create(0, 0, ERX_IRQ_SOFT, 0, &irq)) == ERX_OK && made < 4096)
		made++;
	return (status == ERX_ENOMEM && made > 0);
}

const function_api_case_t function_api_irq_cases[] = {
	{ "irq_refusals", case_irq_refusals },
	{ "irq_wakes_parked", case_irq_wakes_parked },
	{ "irq_objects_run_out", case_irq_objects_run_out },
};
const size_t function_api_irq_case_count = sizeof(function_api_irq_cases) / sizeof(function_api_irq_cases[0]);

const function_api_case_t function_api_hosted_irq_cases[] = {
	{ "irq_refusals", case_irq_refusals },
	{ "irq_line_refused", case_irq_line_refused },
	{ "irq_ready_once", case_irq_ready_once },
	{ "irq_wakes_parked", case_irq_wakes_parked },
	{ "irq_objects_run_out", case_irq_objects_run_out },
};
const size_t function_api_hosted_irq_case_count = sizeof(function_api_hosted_irq_cases) / sizeof(function_api_hosted_irq_cases[0]);
