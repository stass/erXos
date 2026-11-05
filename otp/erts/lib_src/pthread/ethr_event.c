/*
 * %CopyrightBegin%
 *
 * SPDX-License-Identifier: Apache-2.0
 *
 * Copyright Ericsson AB 2009-2025. All Rights Reserved.
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 *
 * Modified by erXos: ETHR_FUTEX__ is erx_umtx_wait and erx_umtx_wake, and the futex form is the one form.
 *
 * %CopyrightEnd%
 */

/*
 * Author: Rickard Green
 */

#define ETHR_INLINE_FUNC_NAME_(X) X ## __
#define ETHR_EVENT_IMPL__

#ifdef HAVE_CONFIG_H
#include "config.h"
#endif


#include "ethread.h"
#undef ETHR_INCLUDE_MONOTONIC_CLOCK__
#define ETHR_INCLUDE_MONOTONIC_CLOCK__
#include "ethr_internal.h"

/* --- Linux futex implementation of ethread events ------------------------- */

#include <sched.h>
#include <errno.h>
#include <limits.h>

#include "liberx/backend/api.h"

#define ETHR_YIELD_AFTER_BUSY_LOOPS 50

/*
 * The adapter of docs/design-runtime.md, "Threads and synchronisation". The word protocol
 * above it is stock's, so what it must keep is the macro's answer: a wake is 0 for any count,
 * and any status it does not name is EINVAL, which stock's fatal branch ends. A relative
 * timeout too large to add to the clock is no deadline.
 */
int
ethr_futex__(ethr_atomic32_t *futex, int op, ethr_sint32_t val,
	     const struct timespec *timeout)
{
    const uint64_t addr = (uint64_t) (uintptr_t) ethr_atomic32_addr(futex);
    uint64_t deadline = ERX_WAIT_FOREVER;

    if (op == ETHR_FUTEX_WAKE__)
	return erx_umtx_wake(addr, (uint32_t) val) < 0 ? EINVAL : 0;

    if (timeout) {
    	uint64_t relative;

    	if (!__builtin_mul_overflow((uint64_t) timeout->tv_sec, UINT64_C(1000000000), &relative)
    	    && !__builtin_add_overflow(relative, (uint64_t) timeout->tv_nsec, &relative))
    	    deadline = erx_deadline_after(relative);
    }

    switch (erx_umtx_wait(addr, (uint32_t) val, deadline)) {
    case ERX_OK:
	return 0;
    case ERX_ETIMEDOUT:
	return ETIMEDOUT;
    case ERX_EINTR:
	return EINTR;
    default:
	return EINVAL;
    }
}

void
ethr_init_event__(void)
{

}

int
ethr_event_init(ethr_event *e)
{
    ethr_atomic32_init(&e->futex, ETHR_EVENT_OFF__);
    return 0;
}

int
ethr_event_prepare_timed(ethr_event *e)
{
    return 0;
}

int
ethr_event_destroy(ethr_event *e)
{
    return 0;
}

static ETHR_INLINE int
wait__(ethr_event *e, int spincount, ethr_sint64_t timeout)
{
    unsigned sc = spincount;
    int res;
    ethr_sint32_t val;
    int until_yield = ETHR_YIELD_AFTER_BUSY_LOOPS;
    ethr_sint64_t time = 0; /* SHUT UP annoying faulty warning... */
    struct timespec ts, *tsp;
#ifdef ETHR_HAVE_ETHR_GET_MONOTONIC_TIME
    ethr_sint64_t start = 0; /* SHUT UP annoying faulty warning... */
#endif
    int timeout_res = ETIMEDOUT;

    if (spincount < 0)
	ETHR_FATAL_ERROR__(EINVAL);

    if (timeout < 0) {
	tsp = NULL;
    }
    else {
#ifdef ETHR_HAVE_ETHR_GET_MONOTONIC_TIME
	start = ethr_get_monotonic_time();
#endif
	tsp = &ts;
	time = timeout;
	if (spincount == 0) {
	    val = ethr_atomic32_read(&e->futex);
	    if (val == ETHR_EVENT_ON__)
		goto return_event_on;
	    goto set_timeout;
	}
    }

    while (1) {
	while (1) {
	    val = ethr_atomic32_read(&e->futex);
	    if (val == ETHR_EVENT_ON__)
		goto return_event_on;
	    if (sc == 0)
		break;
	    sc--;
	    ETHR_SPIN_BODY;
	    if (--until_yield == 0) {
		until_yield = ETHR_YIELD_AFTER_BUSY_LOOPS;
		res = ETHR_YIELD();
		if (res != 0)
		    ETHR_FATAL_ERROR__(res);
	    }
	}

	if (timeout >= 0) {
            ethr_sint64_t sec, nsec;
#ifdef ETHR_HAVE_ETHR_GET_MONOTONIC_TIME
	    time = timeout - (ethr_get_monotonic_time() - start);
#endif
	set_timeout:
	    if (time <= 0) {
		val = ethr_atomic32_read(&e->futex);
		if (val == ETHR_EVENT_ON__)
		    goto return_event_on;
		return ETIMEDOUT;
	    }
            sec = time / (1000*1000*1000);
            nsec = time % (1000*1000*1000);
            if (sizeof(ts.tv_sec) == 8
                || sec <= (ethr_sint64_t) INT_MAX) {
                ts.tv_sec = sec;
                ts.tv_nsec = nsec;
            }
            else {
                ts.tv_sec = INT_MAX;
                ts.tv_nsec = 0;
                timeout_res = EINTR;
            }
	}

	if (val != ETHR_EVENT_OFF_WAITER__) {
	    val = ethr_atomic32_cmpxchg(&e->futex,
					ETHR_EVENT_OFF_WAITER__,
					ETHR_EVENT_OFF__);

	    if (val == ETHR_EVENT_ON__)
		goto return_event_on;
	    ETHR_ASSERT(val == ETHR_EVENT_OFF__);
	}

	res = ETHR_FUTEX__(&e->futex,
			   ETHR_FUTEX_WAIT__,
			   ETHR_EVENT_OFF_WAITER__,
			   tsp);
	switch (res) {
	case ETIMEDOUT:
            res = timeout_res;
            /* Fall through... */
	case EINTR:
	    return res;
	case 0:
	case EWOULDBLOCK:
	    break;
	default:
	    ETHR_FATAL_ERROR__(res);
	}
    }

return_event_on:

    ETHR_MEMBAR(ETHR_LoadLoad|ETHR_LoadStore);

    return 0;

}


void
ethr_event_reset(ethr_event *e)
{
    ethr_event_reset__(e);
}

void
ethr_event_set(ethr_event *e)
{
    ethr_event_set__(e);
}

int
ethr_event_wait(ethr_event *e)
{
    return wait__(e, 0, -1);
}

int
ethr_event_swait(ethr_event *e, int spincount)
{
    return wait__(e, spincount, -1);
}

int
ethr_event_twait(ethr_event *e, ethr_sint64_t timeout)
{
    return wait__(e, 0, timeout);
}

int
ethr_event_stwait(ethr_event *e, int spincount, ethr_sint64_t timeout)
{
    return wait__(e, spincount, timeout);
}
