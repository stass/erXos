/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

#include <sys/mman.h>
#include <sys/stat.h>
#include <sys/sysctl.h>

#include "erx/release.h"
#include "liberx/backend/api.h"
#include "liberx/backend/core/boot_info.h"
#include "liberx/backend/core/boot_manifest.h"
#include "liberx/backend/hosted/internal.h"
#include "liberx/backend/runtime_entry.h"

/*
 * The hosted entry (docs/design-stopgap.md, "The hosted backend"): main(ARCHIVE, ARGS...)
 * maps the boot archive, gathers what the page holds from its manifest and the host, fills
 * the page, and starts ERTS on it. Everything host-specific about a start is here.
 */

#define HOSTED_DOMAIN_ID	4
#define MCPU_PER_CPU		1000
#define NS_PER_S		UINT64_C(1000000000)

extern char **environ;

static _Alignas(ERX_PAGE_SIZE) uint8_t boot_page[ERX_PAGE_SIZE];
static uint64_t wall_offset_ns;

/*
 * The words liberx itself looks for: the group report's (group.c) and the failing entropy
 * reads' (vm.c). They stay beside TZ in libSystem's environment, which only liberx reads:
 * ERTS's environment is the page's.
 */
static const char *const report_words[] = { "ERX_HOSTED_GROUP_REPORT", "ERX_HOSTED_ENTROPY_FAIL" };
#define REPORT_WORDS_COUNT	(sizeof(report_words) / sizeof(report_words[0]))

/* libSystem's own environment: its local time reads TZ, and nothing else of the host's stays. */
static char zone_word[] = "TZ=UTC";
static char *hosted_environ[1 + REPORT_WORDS_COUNT + 1] = { zone_word };

/* What the entry adds after the manifest's words: the console's driver, read at its start. */
static const char console_driver_words[] = ERX_BOOT_RECORD_FLAG "\0console_driver\0erx_stdio";

_Noreturn static void
fail(const char *reason)
{
	fprintf(stderr, "erx: hosted: %s\n", reason);
	exit(1);
}

_Noreturn static void
refuse_archive(const char *reason)
{
	fprintf(stderr, "erx: hosted: boot archive refused: %s\n", reason);
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

static void
keep_report_words(void)
{
	size_t count = 1;

	for (char **entry = environ; *entry != NULL; entry++) {
		for (size_t at = 0; at < REPORT_WORDS_COUNT; at++) {
			const size_t key = strlen(report_words[at]);

			if (count < 1 + REPORT_WORDS_COUNT && strncmp(*entry, report_words[at], key) == 0 && (*entry)[key] == '=')
				hosted_environ[count++] = *entry;
		}
	}
}

/*
 * Maps the archive read-only for the process's life and makes it the release. A file
 * truncated during the run faults, as the host's does.
 */
static void
release_map(const char *path)
{
	struct stat status;
	const char *reason;
	void *bytes;
	int descriptor;

	descriptor = open(path, O_RDONLY);
	if (descriptor < 0 || fstat(descriptor, &status) != 0 || status.st_size <= 0)
		refuse_archive("unreadable");
	bytes = mmap(NULL, (size_t)status.st_size, PROT_READ, MAP_PRIVATE, descriptor, 0);
	close(descriptor);
	if (bytes == MAP_FAILED)
		refuse_archive("unreadable");
	if (erx_release_bind(bytes, (size_t)status.st_size, &reason) != 0)
		refuse_archive(reason);
}

/*
 * The release's manifest, checked against its hash, then by its reader. The hosted entry hands
 * ERTS no device record, so it asks for no host link.
 */
static void
manifest_read(erx_boot_manifest_t *manifest)
{
	const uint8_t *bytes;
	const char *reason;
	size_t length;

	if (erx_release_manifest(&bytes, &length, &reason) != 0 ||
	    !erx_boot_manifest_read(bytes, length, false, manifest, &reason))
		refuse_archive(reason);
}
int
main(int argc, char **argv)
{
	const size_t nwords = argc > 2 ? (size_t)argc - 2 : 0;
	/* The manifest's words and the driver's, then the command line after the archive's path. */
	const size_t nargs = 2 + nwords;
	erx_boot_words_t *const args = calloc(nargs, sizeof(*args));
	const uint32_t cpus = host_cpus();
	erx_boot_manifest_t manifest;
	erx_boot_info_status_t status;

	if (argc < 2)
		fail("usage: beam ARCHIVE [ARGS...]");
	if (args == NULL)
		fail("no memory for the arguments");
	release_map(argv[1]);
	manifest_read(&manifest);
	args[0] = manifest.system_args;
	args[1] = (erx_boot_words_t){ console_driver_words, sizeof(console_driver_words) };
	for (size_t at = 0; at < nwords; at++) {
		/* The NUL is what tells the page an empty argument from no words at all. */
		args[2 + at] = (erx_boot_words_t){ argv[at + 2], strlen(argv[at + 2]) + 1 };
	}
	wall_offset_init();

	const erx_boot_inputs_t inputs = {
		.domain_id = HOSTED_DOMAIN_ID,
		.flags = ERX_BOOT_ROOT,
		.pack_flags = erx_release_pack_flags(),
		.capacity_mcpu = MCPU_PER_CPU * cpus,
		.space = { .raw = ERX_CAP_SELF },
		.group = { .raw = ERX_CAP_SELF },
		.release_addr = (uint64_t)(uintptr_t)erx_release_addr(),
		.cpuset = cpus == 64 ? UINT64_MAX : (UINT64_C(1) << cpus) - 1,
		.node = manifest.node,
		.node_len = manifest.node_len,
		.args = args,
		.nargs = nargs,
		.limits = manifest.limits,
	};

	status = erx_boot_info_build(&inputs, boot_page, sizeof(boot_page));
	if (status != ERX_BOOT_INFO_OK)
		fail(erx_boot_info_reason(status));
	free(args);
	keep_report_words();
	if (getenv("ERX_HOSTED_VM_RUNS") != NULL)
		erx_hosted_vm_report_runs();
	environ = hosted_environ;
	erx_runtime_main();
	return (0);
}
