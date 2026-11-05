/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

#include <sys/sysctl.h>

#include "liberx/backend/api.h"
#include "liberx/backend/core/boot_info.h"
#include "liberx/backend/runtime_entry.h"

/*
 * The hosted entry (docs/design-stopgap.md, "The hosted backend"): gathers what the page
 * holds, fills it, and starts ERTS on it. Everything host-specific about a start is here.
 */

#define HOSTED_NODE		"system@hosted"
#define HOSTED_DOMAIN_ID	4
#define MCPU_PER_CPU		1000
#define NS_PER_S		UINT64_C(1000000000)

extern char **environ;

static _Alignas(ERX_PAGE_SIZE) uint8_t boot_page[ERX_PAGE_SIZE];
static uint64_t wall_offset_ns;

/*
 * What of the host's environment reaches the page: only what the stock fd, spawn and
 * forker ports and the stock terminal driver read, since they find erl_child_setup and
 * the terminal through it.
 */
static const char *const inherited[] = { "BINDIR", "ROOTDIR", "EMU", "PROGNAME", "HOME", "TERM" };
#define INHERITED_COUNT	(sizeof(inherited) / sizeof(inherited[0]))

/* libSystem's own environment: its local time reads TZ, and nothing of the host's stays. */
static char zone_word[] = "TZ=UTC";
static char *hosted_environ[] = { zone_word, NULL };

_Noreturn static void
fail(const char *reason)
{
	fprintf(stderr, "erx: hosted: %s\n", reason);
	exit(1);
}

const erx_boot_info_t *
erx_boot_info(void)
{
	return ((const erx_boot_info_t *)boot_page);
}

bool
erx_time_wall_ns(uint64_t *wall_ns)
{
	*wall_ns = erx_clock_ns() + wall_offset_ns;
	return (true);
}

/* Read once, as the time page's offset is natively: a later step of the host's clock stays out. */
static void
wall_offset_init(void)
{
	struct timespec now;

	if (clock_gettime(CLOCK_REALTIME, &now) != 0)
		fail("the host has no wall clock");
	wall_offset_ns = (uint64_t)now.tv_sec * NS_PER_S + (uint64_t)now.tv_nsec - erx_clock_ns();
}

static size_t
inherited_words(erx_boot_words_t *words)
{
	bool taken[INHERITED_COUNT] = { false };
	size_t count = 0;

	for (char **entry = environ; *entry != NULL; entry++) {
		for (size_t at = 0; at < INHERITED_COUNT; at++) {
			const size_t key = strlen(inherited[at]);

			if (!taken[at] && strncmp(*entry, inherited[at], key) == 0 && (*entry)[key] == '=') {
				taken[at] = true;
				words[count++] = (erx_boot_words_t){ *entry, strlen(*entry) };
			}
		}
	}
	return (count);
}

/* The host's online CPUs, which the interpreter's schedulers take as the group's set. */
static uint32_t
host_cpus(void)
{
	int count = 0;
	size_t size = sizeof(count);

	if (sysctlbyname("hw.activecpu", &count, &size, NULL, 0) != 0 || count <= 0)
		fail("the host does not say how many CPUs it has");
	return (count > 64 ? 64 : (uint32_t)count);
}

int
main(int argc, char **argv)
{
	const size_t nargs = argc > 1 ? (size_t)argc - 1 : 0;
	erx_boot_words_t *const args = calloc(nargs + 1, sizeof(*args));
	erx_boot_words_t env[INHERITED_COUNT];
	const uint32_t cpus = host_cpus();
	erx_boot_info_status_t status;

	if (args == NULL)
		fail("no memory for the arguments");
	for (size_t at = 0; at < nargs; at++) {
		/* The NUL is what tells the page an empty argument from no words at all. */
		args[at] = (erx_boot_words_t){ argv[at + 1], strlen(argv[at + 1]) + 1 };
	}
	wall_offset_init();

	const erx_boot_inputs_t inputs = {
		.domain_id = HOSTED_DOMAIN_ID,
		.flags = ERX_BOOT_ROOT,
		.capacity_mcpu = MCPU_PER_CPU * cpus,
		.group = { .raw = ERX_CAP_SELF },
		.cpuset = cpus == 64 ? UINT64_MAX : (UINT64_C(1) << cpus) - 1,
		.node = HOSTED_NODE,
		.node_len = strlen(HOSTED_NODE),
		.args = args,
		.nargs = nargs,
		.env = env,
		.nenv = inherited_words(env),
	};

	status = erx_boot_info_build(&inputs, boot_page, sizeof(boot_page));
	if (status != ERX_BOOT_INFO_OK)
		fail(erx_boot_info_reason(status));
	free(args);
	environ = hosted_environ;
	erx_runtime_main();
	return (0);
}
