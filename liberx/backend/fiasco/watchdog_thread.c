/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

#include <stdatomic.h>
#include <stdint.h>

#include <l4/sys/consts.h>
#include <l4/sys/factory.h>
#include <l4/sys/ipc.h>
#include <l4/sys/scheduler.h>
#include <l4/sys/thread.h>
#include <l4/sys/utcb.h>

#include "erx/abi.h"
#include "liberx/backend/api.h"
#include "liberx/backend/fiasco/log.h"
#include "liberx/backend/fiasco/pm_wdt.h"
#include "liberx/backend/fiasco/band.h"
#include "liberx/backend/fiasco/root_layout.h"
#include "liberx/backend/fiasco/service.h"
#include "liberx/backend/fiasco/service_task.h"
#include "liberx/backend/fiasco/thread.h"
#include "liberx/backend/fiasco/watchdog_thread.h"

#define WATCHDOG_STACK_BYTES	16384u
/* The thread ticks about once a second, as the kernel's timer does, whatever the period: the
 * board's watchdog, reloaded at each tick, fires ERX_PM_WDT_TIMEOUT_S after the last. */
#define WATCHDOG_TICK_US	UINT64_C(1000000)
/* The kernel-given UTCB area: the first thread has its first slot, the service its second. */
#define WATCHDOG_UTCB_SLOT	2u

static void watchdog_main(void);

static _Alignas(16) uint8_t watchdog_stack[WATCHDOG_STACK_BYTES];
static erx_watchdog_config_t watchdog_config;
static erx_watchdog_mode_t watchdog_mode;
static erx_fiasco_pm_wdt_t watchdog_board;
/* The time of the last pet, 0 before the first. Only erx_watchdog_pet writes it. */
static _Atomic uint64_t watchdog_pet_ns;

int
erx_watchdog_pet(void)
{
	atomic_store_explicit(&watchdog_pet_ns, erx_fiasco_clock_ns(), memory_order_relaxed);
	return (ERX_OK);
}

static void
watchdog_main(void)
{
	const l4_timeout_t tick = l4_timeout(L4_IPC_TIMEOUT_NEVER, l4_timeout_from_us(WATCHDOG_TICK_US));
	erx_watchdog_t state = erx_watchdog_initial();
	erx_watchdog_step_t step;
	uint64_t last_pet = 0, pet;

	step = erx_watchdog_step(&state, &watchdog_config, watchdog_mode,
	    (erx_watchdog_event_t){ .kind = ERX_WATCHDOG_START, .now_ns = erx_fiasco_clock_ns() });
	state = step.next;
	erx_fiasco_pm_wdt_step(&watchdog_board, step.action);
	for (;;) {
		(void)l4_ipc_sleep(tick);
		pet = atomic_load_explicit(&watchdog_pet_ns, memory_order_relaxed);
		if (pet != last_pet) {
			last_pet = pet;
			step = erx_watchdog_step(&state, &watchdog_config, watchdog_mode,
			    (erx_watchdog_event_t){ .kind = ERX_WATCHDOG_PET, .now_ns = pet });
			state = step.next;
		}
		step = erx_watchdog_step(&state, &watchdog_config, watchdog_mode,
		    (erx_watchdog_event_t){ .kind = ERX_WATCHDOG_TICK, .now_ns = erx_fiasco_clock_ns() });
		state = step.next;
		if (step.action == ERX_WATCHDOG_END)
			erx_fiasco_end_watchdog(&step.end);
		erx_fiasco_pm_wdt_step(&watchdog_board, step.action);
	}
}

const char *
erx_fiasco_watchdog_start(const erx_watchdog_config_t *config, erx_watchdog_mode_t mode, const erx_fiasco_pm_wdt_t *board)
{
	const l4_cap_idx_t thread = (l4_cap_idx_t)erx_fiasco_root_slot_cap(ERX_FIASCO_SLOT_WATCHDOG);
	const l4_sched_param_t param = l4_sched_param(erx_fiasco_band_levels(ERX_FIASCO_BAND_WATCHDOG).base,
	    erx_fiasco_task(ERX_FIASCO_TASK_ROOT)->bands.slice_us);

	watchdog_config = *config;
	watchdog_mode = mode;
	watchdog_board = *board;
	if (l4_error(l4_factory_create_thread(L4_BASE_FACTORY_CAP, thread)) < 0)
		return ("watchdog: the kernel refused its thread");
	l4_thread_control_start();
	l4_thread_control_pager(L4_BASE_PAGER_CAP);
	l4_thread_control_exc_handler(L4_BASE_PAGER_CAP);
	l4_thread_control_bind((l4_utcb_t *)((char *)erx_fiasco_thread_first_utcb() + WATCHDOG_UTCB_SLOT * L4_UTCB_OFFSET),
	    L4_BASE_TASK_CAP);
	if (l4_error(l4_thread_control_commit(thread)) < 0)
		return ("watchdog: the kernel refused its thread's control");
	if (l4_error(l4_thread_ex_regs(thread, (l4_addr_t)watchdog_main,
	    (l4_addr_t)(watchdog_stack + sizeof(watchdog_stack)), 0)) < 0)
		return ("watchdog: the kernel refused its registers");
	if (l4_error(l4_scheduler_run_thread(L4_BASE_SCHEDULER_CAP, thread, &param)) < 0)
		return ("watchdog: the kernel would not run it");
	return (NULL);
}
