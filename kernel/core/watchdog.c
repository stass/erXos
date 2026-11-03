/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#include "erx/watchdog.h"

#define ERX_WATCHDOG_NS_PER_S	UINT64_C(1000000000)
#define ERX_WATCHDOG_FIELDS	3

/* The deadline's lower bound, 2P, is computed in 32 bits. */
_Static_assert((uint64_t)ERX_WATCHDOG_DEADLINE_PERIODS_MIN *
    ERX_WATCHDOG_PERIOD_MAX <= UINT32_MAX, "2P fits in 32 bits");

static erx_watchdog_t erx_watchdog_arm_at(uint64_t, uint32_t);
static erx_watchdog_step_t erx_watchdog_end_now(const erx_watchdog_t *,
    uint64_t, erx_crash_cause_t);
static erx_watchdog_parse_status_t erx_watchdog_parse_field(const char **,
    const char *, uint32_t *);
static erx_watchdog_parse_status_t erx_watchdog_parse_fields(const char *,
    size_t, uint32_t *);
static erx_watchdog_step_t erx_watchdog_stay(const erx_watchdog_t *,
    erx_watchdog_action_t);
static bool erx_watchdog_valid(const erx_watchdog_t *, erx_watchdog_mode_t,
    erx_watchdog_event_kind_t);

erx_watchdog_t
erx_watchdog_initial(void)
{
	return ((erx_watchdog_t){ .phase = ERX_WATCHDOG_UNARMED });
}

erx_watchdog_config_t
erx_watchdog_config_default(void)
{
	return ((erx_watchdog_config_t){
		.period_s = ERX_WATCHDOG_PERIOD_DEFAULT,
		.deadline_s = ERX_WATCHDOG_DEADLINE_DEFAULT,
		.boot_s = ERX_WATCHDOG_BOOT_DEFAULT,
	});
}

/*
 * The armed state that starts at since_ns with a deadline seconds ahead. A
 * deadline past the clock's range saturates to UINT64_MAX, which no tick
 * can pass: the kernel clock counts nanoseconds since boot and does not
 * reach it.
 */
static erx_watchdog_t
erx_watchdog_arm_at(uint64_t since_ns, uint32_t seconds)
{
	uint64_t deadline_ns, span_ns;

	if (__builtin_mul_overflow((uint64_t)seconds, ERX_WATCHDOG_NS_PER_S,
	    &span_ns) ||
	    __builtin_add_overflow(since_ns, span_ns, &deadline_ns))
		deadline_ns = UINT64_MAX;
	return ((erx_watchdog_t){
		.phase = ERX_WATCHDOG_ARMED,
		.since_ns = since_ns,
		.deadline_ns = deadline_ns,
	});
}

static erx_watchdog_step_t
erx_watchdog_stay(const erx_watchdog_t *state, erx_watchdog_action_t action)
{
	return ((erx_watchdog_step_t){ .next = *state, .action = action });
}

/*
 * The machine ends with the state unchanged: the end does not return, and
 * a repeated decision ends it again. A missed deadline is the root task's
 * fault and carries the time since its last proof of life; a phase, event
 * or mode outside its enum is the kernel's own bug and is recorded as a
 * panic, so the crash record does not blame the root task for it.
 */
static erx_watchdog_step_t
erx_watchdog_end_now(const erx_watchdog_t *state, uint64_t now_ns,
    erx_crash_cause_t cause)
{
	erx_watchdog_step_t step;

	step = erx_watchdog_stay(state, ERX_WATCHDOG_END);
	step.end.cause = cause;
	step.end.uptime_ns = now_ns;
	if (cause == ERX_CRASH_CAUSE_WATCHDOG && now_ns >= state->since_ns)
		step.end.since_pet_ns = now_ns - state->since_ns;
	return (step);
}

static bool
erx_watchdog_valid(const erx_watchdog_t *state, erx_watchdog_mode_t mode,
    erx_watchdog_event_kind_t kind)
{
	return ((state->phase == ERX_WATCHDOG_UNARMED ||
	    state->phase == ERX_WATCHDOG_ARMED ||
	    state->phase == ERX_WATCHDOG_OFF) &&
	    (mode == ERX_WATCHDOG_MODE_NORMAL ||
	    mode == ERX_WATCHDOG_MODE_DETERMINISTIC) &&
	    (kind == ERX_WATCHDOG_START || kind == ERX_WATCHDOG_PET ||
	    kind == ERX_WATCHDOG_TICK));
}

/*
 * One event's decision:
 *
 *   phase     START             PET                    TICK
 *   unarmed   armed B ahead     ignored                reload
 *             (off when det)
 *   armed     ignored           on time: D ahead;      past deadline: end;
 *                               late: ignored          else reload
 *   off       ignored           accepted, no deadline  reload
 *
 * A pet is on time up to and including the deadline instant. A late pet
 * moves nothing, so the next tick ends the machine: the machine ends
 * exactly when a deadline passes without a pet, and only a tick ends it.
 * A repeated start never re-arms, so it cannot extend a deadline. A tick
 * never changes the state. A phase, mode or event outside its enum ends
 * the machine rather than leave it unguarded.
 */
erx_watchdog_step_t
erx_watchdog_step(const erx_watchdog_t *state,
    const erx_watchdog_config_t *config, erx_watchdog_mode_t mode,
    erx_watchdog_event_t event)
{
	if (!erx_watchdog_valid(state, mode, event.kind))
		return (erx_watchdog_end_now(state, event.now_ns,
		    ERX_CRASH_CAUSE_PANIC));

	switch (event.kind) {
	case ERX_WATCHDOG_START:
		if (state->phase != ERX_WATCHDOG_UNARMED)
			return (erx_watchdog_stay(state, ERX_WATCHDOG_NONE));
		if (mode == ERX_WATCHDOG_MODE_DETERMINISTIC) {
			return ((erx_watchdog_step_t){
				.next = { .phase = ERX_WATCHDOG_OFF },
				.action = ERX_WATCHDOG_NONE,
			});
		}
		return ((erx_watchdog_step_t){
			.next = erx_watchdog_arm_at(event.now_ns,
			    config->boot_s),
			.action = ERX_WATCHDOG_ARM,
		});
	case ERX_WATCHDOG_PET:
		if (state->phase != ERX_WATCHDOG_ARMED ||
		    event.now_ns > state->deadline_ns)
			return (erx_watchdog_stay(state, ERX_WATCHDOG_NONE));
		return ((erx_watchdog_step_t){
			.next = erx_watchdog_arm_at(event.now_ns,
			    config->deadline_s),
			.action = ERX_WATCHDOG_NONE,
		});
	case ERX_WATCHDOG_TICK:
		if (state->phase == ERX_WATCHDOG_ARMED &&
		    event.now_ns > state->deadline_ns)
			return (erx_watchdog_end_now(state, event.now_ns,
			    ERX_CRASH_CAUSE_WATCHDOG));
		return (erx_watchdog_stay(state, ERX_WATCHDOG_RELOAD));
	}
	/* erx_watchdog_valid admitted only the three kinds above. */
	return (erx_watchdog_end_now(state, event.now_ns, ERX_CRASH_CAUSE_PANIC));
}

/*
 * Reads one decimal field at *cursor, up to a comma or the end, and leaves
 * *cursor on the byte that stopped it. The loop is bounded by end, so by
 * the value's length. Every step of the accumulation is checked, so a
 * field of any length either fits in 32 bits or overflows.
 */
static erx_watchdog_parse_status_t
erx_watchdog_parse_field(const char **cursor, const char *end,
    uint32_t *value)
{
	const char *at;
	uint32_t accumulated;

	accumulated = 0;
	for (at = *cursor; at < end && *at != ','; at++) {
		if (*at < '0' || *at > '9')
			return (ERX_WATCHDOG_PARSE_DIGIT);
		if (__builtin_mul_overflow(accumulated, UINT32_C(10),
		    &accumulated) ||
		    __builtin_add_overflow(accumulated,
		    (uint32_t)(*at - '0'), &accumulated))
			return (ERX_WATCHDOG_PARSE_OVERFLOW);
	}
	if (at == *cursor)
		return (ERX_WATCHDOG_PARSE_EMPTY);
	*cursor = at;
	*value = accumulated;
	return (ERX_WATCHDOG_PARSE_OK);
}

/*
 * Splits bytes into exactly three fields separated by single commas. The
 * first problem from the left is the one reported.
 */
static erx_watchdog_parse_status_t
erx_watchdog_parse_fields(const char *bytes, size_t length,
    uint32_t *fields)
{
	erx_watchdog_parse_status_t status;
	const char *cursor, *end;

	cursor = bytes;
	end = bytes + length;
	for (int index = 0; index < ERX_WATCHDOG_FIELDS; index++) {
		status = erx_watchdog_parse_field(&cursor, end, &fields[index]);
		if (status != ERX_WATCHDOG_PARSE_OK)
			return (status);
		if (index < ERX_WATCHDOG_FIELDS - 1) {
			if (cursor == end)
				return (ERX_WATCHDOG_PARSE_FIELDS);
			cursor++;	/* the comma */
		}
	}
	if (cursor != end)
		return (ERX_WATCHDOG_PARSE_FIELDS);
	return (ERX_WATCHDOG_PARSE_OK);
}

/*
 * Parses the value of erx.watchdog=, the length bytes at bytes (no NUL
 * terminator is read, and a NUL among them is a malformed byte). bytes and
 * config are never NULL; an empty value is a non-NULL pointer and 0. On
 * success *config holds P, D and B; on any refusal it holds the defaults,
 * which the boot then uses, and the status names the reason for the early
 * console. The bounds are checked in order, each against the ones before:
 * P alone, D against 2P, B against D.
 */
erx_watchdog_parse_status_t
erx_watchdog_parse(const char *bytes, size_t length,
    erx_watchdog_config_t *config)
{
	erx_watchdog_parse_status_t status;
	uint32_t fields[ERX_WATCHDOG_FIELDS];
	erx_watchdog_config_t parsed;

	*config = erx_watchdog_config_default();
	status = erx_watchdog_parse_fields(bytes, length, fields);
	if (status != ERX_WATCHDOG_PARSE_OK)
		return (status);
	parsed = (erx_watchdog_config_t){
		.period_s = fields[0],
		.deadline_s = fields[1],
		.boot_s = fields[2],
	};

	if (parsed.period_s < ERX_WATCHDOG_PERIOD_MIN ||
	    parsed.period_s > ERX_WATCHDOG_PERIOD_MAX)
		return (ERX_WATCHDOG_PARSE_PERIOD);
	if (parsed.deadline_s <
	    ERX_WATCHDOG_DEADLINE_PERIODS_MIN * parsed.period_s ||
	    parsed.deadline_s > ERX_WATCHDOG_DEADLINE_MAX)
		return (ERX_WATCHDOG_PARSE_DEADLINE);
	if (parsed.boot_s < parsed.deadline_s ||
	    parsed.boot_s > ERX_WATCHDOG_BOOT_MAX)
		return (ERX_WATCHDOG_PARSE_BOOT);

	*config = parsed;
	return (ERX_WATCHDOG_PARSE_OK);
}

const char *
erx_watchdog_parse_reason(erx_watchdog_parse_status_t status)
{
	switch (status) {
	case ERX_WATCHDOG_PARSE_OK:
		return ("valid");
	case ERX_WATCHDOG_PARSE_FIELDS:
		return ("expected three comma-separated fields P,D,B");
	case ERX_WATCHDOG_PARSE_EMPTY:
		return ("a field has no digits");
	case ERX_WATCHDOG_PARSE_DIGIT:
		return ("a field has a byte other than a decimal digit");
	case ERX_WATCHDOG_PARSE_OVERFLOW:
		return ("a field does not fit in 32 bits");
	case ERX_WATCHDOG_PARSE_PERIOD:
		return ("the period P is outside its bounds");
	case ERX_WATCHDOG_PARSE_DEADLINE:
		return ("the deadline D is below 2P or above its bound");
	case ERX_WATCHDOG_PARSE_BOOT:
		return ("the boot deadline B is below D or above its bound");
	}
	return ("unknown status");
}
