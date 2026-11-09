/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

/*
 * The oracle of erx_tcp_cc_cubic's fixed-point arithmetic: FreeBSD's own cubic_k
 * and cubic_cwnd, the inline functions of sys/netinet/cc/cc_cubic.h at the commit
 * NOTICE-freebsd records (deps.lock's freebsd-cc-cubic), compiled on the host by
 * test/host/erx_tcp_cc_cubic_oracle_test.rb, which compares their results with
 * the Erlang translation's.
 *
 * Reads lines "k WMAX_SEGS EPOCH_SEGS" and "c USECS WMAX SMSS K" from standard
 * input and prints each result on a line of its own. Exits 1 at a line it cannot
 * read, so a malformed input is never taken for agreement.
 */

#include <inttypes.h>
#include <limits.h>
#include <math.h>
#include <stdint.h>
#include <stdio.h>

/*
 * What cc_cubic.h takes from FreeBSD's kernel and libkern: hz and tick at
 * FreeBSD's default hz of 1000, lmax, and a declaration of the NewReno helper
 * its unused tf_cwnd calls.
 */
struct cc_var;
unsigned int newreno_cc_cwnd_in_cong_avoid(struct cc_var *);
int hz = 1000;
static const int tick = 1000;

static inline long
lmax(long a, long b)
{
	return (a > b ? a : b);
}

#include "cc_cubic.h"

int
main(void)
{
	int64_t a, b, c, d;
	char op;

	while (scanf(" %c", &op) == 1) {
		if (op == 'k' && scanf("%" SCNd64 " %" SCNd64, &a, &b) == 2)
			printf("%" PRId64 "\n", cubic_k((uint32_t)a, (uint32_t)b));
		else if (op == 'c' && scanf("%" SCNd64 " %" SCNd64 " %" SCNd64
		    " %" SCNd64, &a, &b, &c, &d) == 4)
			printf("%" PRIu32 "\n", cubic_cwnd((int)a, (uint32_t)b,
			    (uint32_t)c, d));
		else
			return (1);
	}
	return (0);
}
