/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

#ifndef ERX_LIBERX_PTHREAD_EXECUTOR_H
#define ERX_LIBERX_PTHREAD_EXECUTOR_H

#include <pthread.h>

/*
 * pthread_create for an executor (docs/design-runtime.md, "Making an executor"): the
 * arguments, the result and the thread are pthread_create's, and the new thread holds a
 * slot in the group from its first instruction until it returns or calls pthread_exit.
 * The caller claims the slot, so no free slot is this call's EAGAIN.
 *
 * Apart from liberx/backend/api.h because the root's freestanding code includes that
 * header with no pthread.h to include.
 */
int	erx_pthread_create_executor(pthread_t *thread, const pthread_attr_t *attr,
	    void *(*start)(void *), void *arg);

#endif /* ERX_LIBERX_PTHREAD_EXECUTOR_H */
