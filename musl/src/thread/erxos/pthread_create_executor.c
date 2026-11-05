/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

/*
 * pthread_create for an executor (docs/design-runtime.md, "Making an executor"): a copy of
 * the attribute with the one field only this function writes. __pthread_create turns it
 * into ERX_CLONE_EXECUTOR and __clone into the thread's class, so the thread is an
 * executor from its first instruction. No free slot is __clone's failure, so EAGAIN.
 */

#define _GNU_SOURCE

#include <pthread.h>

#include "pthread_impl.h"

#include "liberx/pthread_executor.h"

int
erx_pthread_create_executor(pthread_t *thread, const pthread_attr_t *attrp, void *(*start)(void *), void *arg)
{
	pthread_attr_t attr;
	int status;

	if (attrp != NULL)
		attr = *attrp;
	else if ((status = pthread_attr_init(&attr)) != 0)
		return (status);
	attr._a_executor = 1;
	return (__pthread_create(thread, &attr, start, arg));
}
