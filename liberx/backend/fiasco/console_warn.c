/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

/*
 * console_warn, the test program of tools/lib/erx/native_console_ring.rb: one
 * marked receive, a receive from the thread itself whose zero timeout hits
 * before it would wait, as a yield's does, with the label ERX_TEST_KERNEL_WARN
 * in its tag (docs/design-fiasco.md, "Test kernels' seeds"). On the case's test
 * kernel the first such receive prints one warning and the second overflows the
 * kernel's ring console and traps; on any other kernel it is an ordinary yield.
 * The define has no default, so only the case's build, which sets it, builds
 * this program.
 */

#include <l4/sys/ipc.h>
#include <l4/sys/utcb.h>

int	main(void);

int
main(void)
{
	l4_umword_t label;

	(void)l4_ipc(L4_INVALID_CAP, l4_utcb(), L4_SYSF_RECV, 0, l4_msgtag(ERX_TEST_KERNEL_WARN, 0, 0, 0), &label,
	    L4_IPC_BOTH_TIMEOUT_0);
	return (0);
}
