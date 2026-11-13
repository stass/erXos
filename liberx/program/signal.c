/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

/*
 * A program's signal dispositions (signal.h).  The table is indexed by the
 * signal's number in the ABI file's signal table, every entry zero, SIG_DFL,
 * at start, and its lock is taken only here, for a copy in or out.
 */

#include <errno.h>
#include <pthread.h>
#include <signal.h>
#include <stdatomic.h>
#include <stdbool.h>
#include <stdint.h>

#include "erx/abi.h"
#include "liberx/backend/api.h"
#include "liberx/program/signal.h"

static pthread_mutex_t actions_lock = PTHREAD_MUTEX_INITIALIZER;
static struct sigaction actions[ERX_SIGRTMAX + 1];

void
erx_prog_sig_start(const erx_prog_sigset_t *ignored)
{
	for (int signo = 1; signo <= ERX_SIGRTMAX; signo++) {
		const uint64_t word = ignored->bits[(signo - 1) / 64];
		const bool asked = (word >> ((signo - 1) % 64)) & 1;

		/* Only a signal sigaction could set to SIG_IGN starts ignored. */
		actions[signo].sa_handler = asked && erx_sig_valid(signo) && signo != ERX_SIGKILL &&
		    signo != ERX_SIGSTOP ? SIG_IGN : SIG_DFL;
	}
}

int
erx_prog_sig_check(int signo, const struct sigaction *act)
{
	if (!erx_sig_valid(signo))
		return (-EINVAL);
	if (act == NULL)
		return (0);
	/* SIGKILL and SIGSTOP keep SIG_DFL, which sigaction may still set, as FreeBSD's kern_sig.c allows. */
	if ((signo == ERX_SIGKILL || signo == ERX_SIGSTOP) && act->sa_handler != SIG_DFL)
		return (-EINVAL);
	/* Only SIG_DFL and SIG_IGN: a handler needs the upcalls the stopgap does not carry. */
	if (act->sa_handler != SIG_DFL && act->sa_handler != SIG_IGN)
		return (-EINVAL);
	return (0);
}

erx_prog_sig_fate_t
erx_prog_sig_fate(int signo, bool ignored)
{
	if (ignored)
		return (ERX_PROG_SIG_DROP);
	/* A stop has no job control to stop under in the first tier, so it is dropped. */
	return (erx_sig_action(signo) == ERX_SIG_ACTION_TERMINATE ? ERX_PROG_SIG_END : ERX_PROG_SIG_DROP);
}

int
erx_prog_sigaction(int signo, const struct sigaction *act, struct sigaction *old)
{
	const int status = erx_prog_sig_check(signo, act);
	struct sigaction was;

	if (status != 0)
		return (status);
	(void)pthread_mutex_lock(&actions_lock);
	was = actions[signo];
	if (act != NULL)
		actions[signo] = *act;
	(void)pthread_mutex_unlock(&actions_lock);
	if (old != NULL)
		*old = was;
	return (0);
}

void
erx_prog_sig_raise(int signo)
{
	static _Atomic uint32_t never;
	bool ignored;

	(void)pthread_mutex_lock(&actions_lock);
	ignored = actions[signo].sa_handler == SIG_IGN;
	(void)pthread_mutex_unlock(&actions_lock);
	if (erx_prog_sig_fate(signo, ignored) == ERX_PROG_SIG_DROP)
		return;
	(void)erx_space_stop(ERX_CAP_SELF, ERX_EXIT_SIGNAL + signo);
	for (;;)
		(void)erx_umtx_wait((uint64_t)(uintptr_t)&never, 0, ERX_WAIT_FOREVER);
}
