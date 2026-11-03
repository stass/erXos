/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

#include <errno.h>
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

#include "erx/watchdog.h"

int LLVMFuzzerTestOneInput(const uint8_t *, size_t);

static bool fuzz_expected(const uint8_t *, size_t, uint64_t *);

/*
 * An independent reading of erx.watchdog=: the value is accepted when it
 * is only digits and exactly two commas with no empty field, each field
 * converts with strtoull without range error, and the three values lie
 * within the generated bounds.
 */
static bool
fuzz_expected(const uint8_t *bytes, size_t length, uint64_t *values)
{
	char *copy, *field, *end;
	size_t commas;
	bool valid;

	commas = 0;
	for (size_t index = 0; index < length; index++) {
		if (bytes[index] == ',')
			commas++;
		else if (bytes[index] < '0' || bytes[index] > '9')
			return (false);
	}
	if (commas != 2 || (copy = malloc(length + 1)) == NULL)
		return (false);
	memcpy(copy, bytes, length);
	copy[length] = '\0';

	valid = true;
	field = copy;
	for (int index = 0; index < 3 && valid; index++) {
		errno = 0;
		values[index] = strtoull(field, &end, 10);
		valid = end != field && errno == 0 &&
		    (*end == ',' || (index == 2 && *end == '\0'));
		field = end + 1;
	}
	free(copy);

	return (valid && values[0] <= UINT32_MAX && values[1] <= UINT32_MAX &&
	    values[2] <= UINT32_MAX &&
	    values[0] >= ERX_WATCHDOG_PERIOD_MIN &&
	    values[0] <= ERX_WATCHDOG_PERIOD_MAX &&
	    values[1] >= (uint64_t)ERX_WATCHDOG_DEADLINE_PERIODS_MIN * values[0] &&
	    values[1] <= ERX_WATCHDOG_DEADLINE_MAX &&
	    values[2] >= values[1] && values[2] <= ERX_WATCHDOG_BOOT_MAX);
}

/*
 * Any byte string is a candidate value. The parser must accept exactly the
 * values fuzz_expected accepts, with the same P, D and B, and leave the
 * defaults on every refusal. libFuzzer's exact-length buffer lets
 * AddressSanitizer catch a read past the value.
 */
int
LLVMFuzzerTestOneInput(const uint8_t *bytes, size_t length)
{
	erx_watchdog_parse_status_t status;
	erx_watchdog_config_t config, defaults;
	uint64_t values[3];
	bool expected;

	defaults = erx_watchdog_config_default();
	expected = fuzz_expected(bytes, length, values);
	status = erx_watchdog_parse((const char *)bytes, length, &config);
	if ((status == ERX_WATCHDOG_PARSE_OK) != expected)
		abort();
	if (expected && (config.period_s != values[0] ||
	    config.deadline_s != values[1] || config.boot_s != values[2]))
		abort();
	if (!expected && (config.period_s != defaults.period_s ||
	    config.deadline_s != defaults.deadline_s ||
	    config.boot_s != defaults.boot_s))
		abort();
	return (0);
}
