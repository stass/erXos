/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

/*
 * The programs suite's program whose startup message is larger than its
 * channel's 16 KiB ring (tools/lib/erx/programs.rb, the bigargs case): one
 * argument of BIG bytes of 'x', which reaches it only if the session writes
 * the message as room returns and liberx's executor copies it as it is
 * published. Beside the argument it checks what its first thread's
 * argument registers held (docs/design-programs.md, "The channel"): the
 * five object values of program_arg, each a capability, all distinct, then
 * the two CPU feature words musl's auxiliary vector holds, and 0 past them;
 * that the session's ring of the program's doorbell reaches the executor
 * with the channel's fixed label, ERX_PROG_CHANNEL_LABEL, the label that
 * also wakes a sender waiting for room, and that no delivery carried
 * another; and that the feature words claim what a domain's do
 * (test/guest/native_musl/guest.c, case_auxv). It ends with 0 when all
 * agree, and with a code of its own for the first that does not.
 *
 * The startup message need not make the session ring. The session runs in
 * a band above a program's, so on a CPU they share it refills the ring
 * before the executor finds it empty, and the executor never arms its read.
 *
 * So main rings it another way: it sleeps, so the executor, with the lane
 * empty, arms its read, publishing its wake, and parks; then it probes
 * itself, a request the program's handler answers with ok. The reply is the
 * first record past the wake, so its write crosses it and the session rings
 * the doorbell. The executor counts the label once it finds the lane empty
 * again, which may come after main looks on another CPU, so main sleeps and
 * probes until the count moves, at most PROBES times.
 */

#include <errno.h>
#include <stdatomic.h>
#include <stddef.h>
#include <string.h>
#include <sys/auxv.h>
#include <time.h>

#include "liberx/backend/api.h"
#include "liberx/program/program.h"
#include "liberx/program/signal.h"

#define BIG	130000u
#define PROBES	100u
#define NAP_NS	1000000L

int	main(int, char **, char **);

/*
 * Whether AT_HWCAP has FP and Advanced SIMD, which every CPU erXos runs on has, and
 * nothing the kernel does not save or emulate, and AT_HWCAP2 claims nothing, as the
 * domain library gives a domain (liberx/backend/core/arch/aarch64/cpu_features.c).
 */
static int
features_given(void)
{
	const unsigned long never = HWCAP_SVE | HWCAP_PACA | HWCAP_PACG | HWCAP_CPUID;
	unsigned long hwcap;

	errno = 0;
	hwcap = getauxval(AT_HWCAP);
	return ((hwcap & HWCAP_FP) != 0 && (hwcap & HWCAP_ASIMD) != 0 && (hwcap & never) == 0 &&
	    getauxval(AT_HWCAP2) == 0 && errno == 0);
}

/*
 * Whether the registers hold five distinct capabilities, then AT_HWCAP and AT_HWCAP2 as
 * musl's start took them, then zeros, and the budget allocates.
 */
static int
registers_hold_the_install(const uint64_t regs[ERX_ARCH_START_ARGS])
{
	uint64_t mem;

	if (regs[ERX_PROGRAM_ARG_HWCAP] != getauxval(AT_HWCAP) ||
	    regs[ERX_PROGRAM_ARG_HWCAP2] != getauxval(AT_HWCAP2))
		return (0);
	for (size_t at = 0; at < ERX_ARCH_START_ARGS; at++) {
		if (at == ERX_PROGRAM_ARG_HWCAP || at == ERX_PROGRAM_ARG_HWCAP2)
			continue;
		if ((at <= ERX_PROGRAM_ARG_DOORBELL) != (regs[at] != ERX_CAP_NULL))
			return (0);
		for (size_t other = 0; other < at && at <= ERX_PROGRAM_ARG_DOORBELL; other++) {
			if (regs[other] == regs[at])
				return (0);
		}
	}
	if (erx_mem_create(regs[ERX_PROGRAM_ARG_BUDGET], ERX_PAGE_SIZE, 0, &mem) != ERX_OK)
		return (0);
	return (erx_object_destroy(mem) == ERX_OK);
}

/*
 * After a sleep of NAP, which lets the executor arm its read and park, probes
 * the program itself, until the executor has counted a ring with the
 * channel's label, at most PROBES times: 0 once it has, 5 if it never does,
 * and 8 for a probe the handler does not answer with ok.
 */
static int
probes_ring(const erx_prog_self_t *self)
{
	const struct timespec nap = { .tv_sec = 0, .tv_nsec = NAP_NS };

	for (unsigned probe = 0; probe < PROBES; probe++) {
		nanosleep(&nap, NULL);
		if (atomic_load_explicit(&self->rings, memory_order_relaxed) != 0)
			return (0);
		if (erx_prog_kill((int)self->pid, 0) != 0)
			return (8);
	}
	return (atomic_load_explicit(&self->rings, memory_order_relaxed) != 0 ? 0 : 5);
}
int
main(int argc, char **argv, char **envp)
{
	const erx_prog_self_t *const self = erx_prog_self();
	int status;

	(void)envp;
	if (argc != 2 || strcmp(argv[0], "bigargs") != 0)
		return (1);
	if (strlen(argv[1]) != BIG)
		return (2);
	for (size_t at = 0; at < BIG; at++) {
		if (argv[1][at] != 'x')
			return (3);
	}
	if (!registers_hold_the_install(self->regs))
		return (4);
	if ((status = probes_ring(self)) != 0)
		return (status);
	if (self->strays != 0)
		return (6);
	if (!features_given())
		return (7);
	return (0);
}
