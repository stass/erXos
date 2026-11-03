/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

/*
 * Runs the watchdog core over the requests in a text file, one per line,
 * and prints one answer line per request, so the host test can judge it.
 * Numbers are decimal; names stand for enum values, and "bogus" for a value
 * outside every enum.
 *
 *   step P D B MODE PHASE SINCE DEADLINE KIND NOW
 *     -> step PHASE SINCE DEADLINE ACTION CAUSE UPTIME SINCE_PET
 *   trace P D B MODE KIND NOW KIND NOW ...
 *     -> one step answer per event, from erx_watchdog_initial onwards
 *   parse HEX        (the value's bytes in hexadecimal, "-" for none)
 *     -> parse STATUS P D B REASON
 *   initial          -> initial PHASE SINCE DEADLINE
 *   default          -> default P D B
 */

#include <inttypes.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "erx/watchdog.h"

#define DRIVER_BOGUS	99

typedef struct driver_name driver_name_t;

struct driver_name {
	const char	*name;
	int		 value;
};

static const driver_name_t driver_phases[] = {
	{ "unarmed", ERX_WATCHDOG_UNARMED },
	{ "armed", ERX_WATCHDOG_ARMED },
	{ "off", ERX_WATCHDOG_OFF },
	{ "bogus", DRIVER_BOGUS },
	{ NULL, 0 },
};

static const driver_name_t driver_kinds[] = {
	{ "start", ERX_WATCHDOG_START },
	{ "pet", ERX_WATCHDOG_PET },
	{ "tick", ERX_WATCHDOG_TICK },
	{ "bogus", DRIVER_BOGUS },
	{ NULL, 0 },
};

static const driver_name_t driver_modes[] = {
	{ "normal", ERX_WATCHDOG_MODE_NORMAL },
	{ "det", ERX_WATCHDOG_MODE_DETERMINISTIC },
	{ "bogus", DRIVER_BOGUS },
	{ NULL, 0 },
};

static const driver_name_t driver_actions[] = {
	{ "none", ERX_WATCHDOG_NONE },
	{ "arm", ERX_WATCHDOG_ARM },
	{ "reload", ERX_WATCHDOG_RELOAD },
	{ "end", ERX_WATCHDOG_END },
	{ NULL, 0 },
};

static const driver_name_t driver_statuses[] = {
	{ "ok", ERX_WATCHDOG_PARSE_OK },
	{ "fields", ERX_WATCHDOG_PARSE_FIELDS },
	{ "empty", ERX_WATCHDOG_PARSE_EMPTY },
	{ "digit", ERX_WATCHDOG_PARSE_DIGIT },
	{ "overflow", ERX_WATCHDOG_PARSE_OVERFLOW },
	{ "period", ERX_WATCHDOG_PARSE_PERIOD },
	{ "deadline", ERX_WATCHDOG_PARSE_DEADLINE },
	{ "boot", ERX_WATCHDOG_PARSE_BOOT },
	{ NULL, 0 },
};

static _Noreturn void driver_fail(const char *, unsigned long);
static const char *driver_name_of(const driver_name_t *, int);
static int driver_value_of(const driver_name_t *, const char *,
    unsigned long);
static void driver_parse(const char *, unsigned long);
static void driver_print_step(const erx_watchdog_step_t *);
static void driver_step(const char *, unsigned long);
static void driver_trace(const char *, unsigned long);

static void
driver_fail(const char *reason, unsigned long line)
{
	fprintf(stderr, "watchdog_driver: line %lu: %s\n", line, reason);
	exit(2);
}

static const char *
driver_name_of(const driver_name_t *names, int value)
{
	for (; names->name != NULL; names++) {
		if (names->value == value)
			return (names->name);
	}
	return ("unknown");
}

static int
driver_value_of(const driver_name_t *names, const char *name,
    unsigned long line)
{
	for (; names->name != NULL; names++) {
		if (strcmp(names->name, name) == 0)
			return (names->value);
	}
	driver_fail("unknown name", line);
}

static void
driver_step(const char *request, unsigned long line)
{
	char mode[16], phase[16], kind[16];
	erx_watchdog_config_t config;
	erx_watchdog_event_t event;
	erx_watchdog_step_t step;
	erx_watchdog_t state;

	if (sscanf(request, "step %" SCNu32 " %" SCNu32 " %" SCNu32
	    " %15s %15s %" SCNu64 " %" SCNu64 " %15s %" SCNu64,
	    &config.period_s, &config.deadline_s, &config.boot_s, mode, phase,
	    &state.since_ns, &state.deadline_ns, kind, &event.now_ns) != 9)
		driver_fail("malformed step", line);
	state.phase = (erx_watchdog_phase_t)driver_value_of(driver_phases,
	    phase, line);
	event.kind = (erx_watchdog_event_kind_t)driver_value_of(driver_kinds,
	    kind, line);
	step = erx_watchdog_step(&state, &config,
	    (erx_watchdog_mode_t)driver_value_of(driver_modes, mode, line),
	    event);
	driver_print_step(&step);
}

/* Threads the state from erx_watchdog_initial through every event. */
static void
driver_trace(const char *request, unsigned long line)
{
	char kind[16], mode_name[16];
	erx_watchdog_config_t config;
	erx_watchdog_event_t event;
	erx_watchdog_step_t step;
	erx_watchdog_mode_t mode;
	erx_watchdog_t state;
	int consumed;

	if (sscanf(request, "trace %" SCNu32 " %" SCNu32 " %" SCNu32 " %15s%n",
	    &config.period_s, &config.deadline_s, &config.boot_s, mode_name,
	    &consumed) != 4)
		driver_fail("malformed trace", line);
	mode = (erx_watchdog_mode_t)driver_value_of(driver_modes, mode_name,
	    line);
	state = erx_watchdog_initial();
	for (request += consumed; sscanf(request, " %15s %" SCNu64 "%n", kind,
	    &event.now_ns, &consumed) == 2; request += consumed) {
		event.kind = (erx_watchdog_event_kind_t)driver_value_of(
		    driver_kinds, kind, line);
		step = erx_watchdog_step(&state, &config, mode, event);
		driver_print_step(&step);
		state = step.next;
	}
}

static void
driver_print_step(const erx_watchdog_step_t *step)
{
	printf("step %s %" PRIu64 " %" PRIu64 " %s %" PRIu32 " %" PRIu64
	    " %" PRIu64 "\n", driver_name_of(driver_phases, step->next.phase),
	    step->next.since_ns, step->next.deadline_ns,
	    driver_name_of(driver_actions, step->action), step->end.cause,
	    step->end.uptime_ns, step->end.since_pet_ns);
}

static void
driver_parse(const char *hex, unsigned long line)
{
	erx_watchdog_parse_status_t status;
	erx_watchdog_config_t config;
	size_t digits, length;
	char *bytes;

	digits = strcspn(hex, "\n");
	if (digits == 1 && hex[0] == '-')
		digits = 0;
	if (digits % 2 != 0)
		driver_fail("odd hex length", line);
	length = digits / 2;
	/* One spare byte so an empty value still has a distinct buffer. */
	if ((bytes = malloc(length + 1)) == NULL)
		driver_fail("out of memory", line);
	for (size_t index = 0; index < length; index++) {
		unsigned byte;

		if (sscanf(hex + 2 * index, "%2x", &byte) != 1)
			driver_fail("malformed hex", line);
		bytes[index] = (char)byte;
	}
	/* Poison the byte after the value: the parser must not read it. */
	bytes[length] = '7';
	status = erx_watchdog_parse(bytes, length, &config);
	printf("parse %s %" PRIu32 " %" PRIu32 " %" PRIu32 " %s\n",
	    driver_name_of(driver_statuses, status), config.period_s,
	    config.deadline_s, config.boot_s,
	    erx_watchdog_parse_reason(status));
	free(bytes);
}

int
main(int argc, char **argv)
{
	erx_watchdog_config_t config;
	erx_watchdog_t state;
	unsigned long line;
	size_t capacity;
	char *request;
	FILE *input;

	if (argc != 2 || (input = fopen(argv[1], "r")) == NULL)
		driver_fail("usage: watchdog_driver REQUESTS", 0);
	request = NULL;
	capacity = 0;
	for (line = 1; getline(&request, &capacity, input) != -1; line++) {
		if (strncmp(request, "step ", 5) == 0) {
			driver_step(request, line);
		} else if (strncmp(request, "trace ", 6) == 0) {
			driver_trace(request, line);
		} else if (strncmp(request, "parse ", 6) == 0) {
			driver_parse(request + 6, line);
		} else if (strcmp(request, "initial\n") == 0) {
			state = erx_watchdog_initial();
			printf("initial %s %" PRIu64 " %" PRIu64 "\n",
			    driver_name_of(driver_phases, state.phase),
			    state.since_ns, state.deadline_ns);
		} else if (strcmp(request, "default\n") == 0) {
			config = erx_watchdog_config_default();
			printf("default %" PRIu32 " %" PRIu32 " %" PRIu32 "\n",
			    config.period_s, config.deadline_s, config.boot_s);
		} else {
			driver_fail("unknown request", line);
		}
	}
	free(request);
	fclose(input);
	return (ferror(stdout) || fflush(stdout) != 0 ? 1 : 0);
}
