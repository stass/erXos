/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

#ifndef ERX_WATCHDOG_H
#define ERX_WATCHDOG_H

#include <stddef.h>
#include <stdint.h>

#include "erx/abi.h"
#include "erx/cdefs.h"
#include "erx/core/watchdog.h"

/*
 * The kernel's watchdog guards the root task. The kernel arms it when it
 * starts the root task, with a deadline the boot deadline B ahead; each pet
 * moves the deadline the deadline D ahead of the pet; the kernel's timer
 * ticks about once a second and, at the first tick past a deadline that no
 * pet moved, the machine ends with a crash record whose cause is
 * ERX_CRASH_CAUSE_WATCHDOG. Every other tick reloads the board's hardware
 * watchdog. In deterministic mode the root task's start turns the watchdog
 * off instead: pets are accepted and set no deadline.
 *
 * erx_watchdog_step decides all of this as a pure function of the current
 * state, the configuration, the mode and one event; the caller stores the
 * next state and performs the action. Times are the kernel clock's
 * nanoseconds since boot, the unit of the crash record's uptime_ns and
 * since_pet_ns.
 *
 * The caller serializes the events on one watchdog state, so a step reads
 * the state the previous step stored. A tick never changes the state, so
 * a tick path need not store it; only the start and pets write it.
 *
 * Every enum starts at 1, so a zeroed value is outside its enum; a phase,
 * mode or event kind outside its enum is a kernel bug, and the step ends
 * the machine with cause ERX_CRASH_CAUSE_PANIC rather than leave the
 * machine unguarded.
 */

typedef enum erx_watchdog_phase {
	ERX_WATCHDOG_UNARMED = 1,	/* the root task has not started */
	ERX_WATCHDOG_ARMED,		/* a deadline is set */
	ERX_WATCHDOG_OFF		/* deterministic mode: never ends */
} erx_watchdog_phase_t;

typedef enum erx_watchdog_event_kind {
	ERX_WATCHDOG_START = 1,		/* the kernel starts the root task */
	ERX_WATCHDOG_PET,		/* the root task's erx_watchdog_pet */
	ERX_WATCHDOG_TICK		/* the kernel's timer checks the deadline */
} erx_watchdog_event_kind_t;

typedef enum erx_watchdog_mode {
	ERX_WATCHDOG_MODE_NORMAL = 1,
	ERX_WATCHDOG_MODE_DETERMINISTIC	/* erx.det=1 */
} erx_watchdog_mode_t;

typedef enum erx_watchdog_action {
	ERX_WATCHDOG_NONE = 1,		/* nothing to do beyond storing next */
	ERX_WATCHDOG_ARM,		/* the start set the first deadline */
	ERX_WATCHDOG_RELOAD,		/* reload the board's hardware watchdog */
	ERX_WATCHDOG_END		/* end the machine; see erx_watchdog_end_t */
} erx_watchdog_action_t;

typedef struct erx_watchdog erx_watchdog_t;
typedef struct erx_watchdog_end erx_watchdog_end_t;
typedef struct erx_watchdog_event erx_watchdog_event_t;
typedef struct erx_watchdog_step erx_watchdog_step_t;

/*
 * since_ns and deadline_ns hold meaning only while armed, and are zero in
 * the other phases. deadline_ns is the last instant at which a pet is on
 * time; it is since_ns plus B or D, or UINT64_MAX when that sum does not
 * fit, so a deadline beyond the clock's range is never reached.
 */
struct erx_watchdog {
	erx_watchdog_phase_t phase;
	uint64_t	since_ns;	/* the root task's start or last pet */
	uint64_t	deadline_ns;
};

struct erx_watchdog_event {
	erx_watchdog_event_kind_t kind;
	uint64_t	now_ns;
};

/*
 * What the crash record of a watchdog end carries. cause is
 * ERX_CRASH_CAUSE_WATCHDOG for a missed deadline, with since_pet_ns the
 * time since the last on-time pet, or since the start before the first;
 * it is ERX_CRASH_CAUSE_PANIC, with since_pet_ns zero, for a value outside
 * its enum.
 */
struct erx_watchdog_end {
	erx_crash_cause_t cause;
	uint64_t	uptime_ns;	/* the event that ended the machine */
	uint64_t	since_pet_ns;
};

/* end is meaningful only when action is ERX_WATCHDOG_END, else zero. */
struct erx_watchdog_step {
	erx_watchdog_t	next;
	erx_watchdog_action_t action;
	erx_watchdog_end_t end;
};

erx_watchdog_t erx_watchdog_initial(void);
erx_watchdog_step_t erx_watchdog_step(const erx_watchdog_t *,
    const erx_watchdog_config_t *, erx_watchdog_mode_t,
    erx_watchdog_event_t);

#endif /* ERX_WATCHDOG_H */
