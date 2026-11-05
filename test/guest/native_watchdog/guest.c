/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

/*
 * The watchdog's transcript, which tools/lib/erx/native_watchdog.rb judges: pets keep
 * the machine up past every deadline, then they stop while this thread spins, so
 * only a thread that outranks it can end the machine, with the record that says why.
 */

#include <stdint.h>

#include "liberx/backend/api.h"
#include "liberx/backend/fiasco/console.h"
#include "liberx/backend/fiasco/log.h"
#include "liberx/backend/fiasco/service.h"
#include "liberx/backend/fiasco/watchdog_thread.h"

#define NS_PER_MS	UINT64_C(1000000)
#define PET_NS		(UINT64_C(200) * NS_PER_MS)
/* Past B and D of the arguments below, with room for a loaded host. */
#define PETTING_NS	(UINT64_C(5000) * NS_PER_MS)
#define PATIENCE_NS	(UINT64_C(30000) * NS_PER_MS)

void erx_fiasco_root_main(void);

static void
say(const char *text)
{
	size_t length = 0;

	while (text[length] != '\0')
		length++;
	erx_fiasco_console_write(text, length);
}

void
erx_fiasco_root_main(void)
{
	/* erx.watchdog=P,D,B in the form the command line gives it. */
	static const char argument[] = "1,2,2";
	const char *reason = erx_fiasco_root_up(NULL, 0);
	erx_watchdog_config_t config;
	uint64_t now, stop;

	if (reason != NULL) {
		say(reason);
		erx_fiasco_machine_off();
	}
	if (erx_watchdog_parse(argument, sizeof(argument) - 1, &config) != ERX_WATCHDOG_PARSE_OK) {
		say("erx: watchdog: the argument did not parse FAILED\n");
		erx_fiasco_machine_off();
	}
	reason = erx_fiasco_watchdog_start(&config, ERX_WATCHDOG_MODE_NORMAL);
	if (reason != NULL) {
		say(reason);
		erx_fiasco_machine_off();
	}
	say("erx: watchdog: armed\n");
	stop = erx_fiasco_clock_ns() + PETTING_NS;
	while ((now = erx_fiasco_clock_ns()) < stop) {
		(void)erx_watchdog_pet();
		while (erx_fiasco_clock_ns() < now + PET_NS)
			continue;
	}
	say("erx: watchdog: pets kept it up\n");
	stop = erx_fiasco_clock_ns() + PATIENCE_NS;
	while (erx_fiasco_clock_ns() < stop)
		continue;
	say("erx: watchdog: UNCAUGHT the machine outlived its deadline\n");
	erx_fiasco_machine_off();
}
