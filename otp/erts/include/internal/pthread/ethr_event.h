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
 * Modified by erXos: events are the futex form over erx_umtx_wait and erx_umtx_wake in every build.
 *
 * %CopyrightEnd%
 */

/*
 * Author: Rickard Green
 */

#if !defined(__erxos__)
#error "events have one form, and every erXos compile line defines __erxos__"
#endif

/* --- The futex form of ethread events, over liberx's umtx ------------------ */

#include <errno.h>
#include <sys/time.h>

#define ETHR_EVENT_OFF_WAITER__		((ethr_sint32_t) -1)
#define ETHR_EVENT_OFF__		((ethr_sint32_t) 1)
#define ETHR_EVENT_ON__ 		((ethr_sint32_t) 0)

/* Which of the two calls ethr_futex__ makes. */
#define ETHR_FUTEX_WAIT__ 0
#define ETHR_FUTEX_WAKE__ 1

typedef struct {
    ethr_atomic32_t futex;
} ethr_event;

/* Answers as a futex call through errno would: 0 or a positive errno value. */
int ethr_futex__(ethr_atomic32_t *futex, int op, ethr_sint32_t val,
		 const struct timespec *timeout);

#define ETHR_FUTEX__(FTX, OP, VAL, TIMEOUT)		\
  ethr_futex__((FTX), (OP), (VAL), (TIMEOUT))

#if defined(ETHR_TRY_INLINE_FUNCS) || defined(ETHR_EVENT_IMPL__)

static void ETHR_INLINE
ETHR_INLINE_FUNC_NAME_(ethr_event_set)(ethr_event *e)
{
    ethr_sint32_t val;
    val = ethr_atomic32_xchg_mb(&e->futex, ETHR_EVENT_ON__);
    if (val == ETHR_EVENT_OFF_WAITER__) {
	int res = ETHR_FUTEX__(&e->futex, ETHR_FUTEX_WAKE__, 1, NULL);
	if (res != 0)
	    ETHR_FATAL_ERROR__(res);
    }
}

static void ETHR_INLINE
ETHR_INLINE_FUNC_NAME_(ethr_event_reset)(ethr_event *e)
{
    ethr_atomic32_set(&e->futex, ETHR_EVENT_OFF__);
    ETHR_MEMORY_BARRIER;
}

#endif


int ethr_event_init(ethr_event *e);
int ethr_event_prepare_timed(ethr_event *e);
int ethr_event_destroy(ethr_event *e);
int ethr_event_wait(ethr_event *e);
int ethr_event_swait(ethr_event *e, int spincount);
int ethr_event_twait(ethr_event *e, ethr_sint64_t timeout);
int ethr_event_stwait(ethr_event *e, int spincount, ethr_sint64_t timeout);
#if !defined(ETHR_TRY_INLINE_FUNCS) || defined(ETHR_EVENT_IMPL__)
void ethr_event_set(ethr_event *e);
void ethr_event_reset(ethr_event *e);
#endif
