/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

/*
 * The process's one group of executors and its IRQ objects, over the park core
 * both backends run (docs/design-stopgap.md, "The park protocol"). A trigger has no
 * dispatcher to go through here: the object fires in the caller's thread.
 */

#include <pthread.h>
#include <stdatomic.h>
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#include "erx/abi.h"
#include "liberx/backend/api.h"
#include "liberx/backend/core/park_table.h"
#include "liberx/backend/hosted/internal.h"

/* An object's handle: never one of a thread's, so neither names the other. */
#define IRQ_HANDLE_BASE	UINT64_C(0x20000)

_Static_assert(ERX_NO_EXECUTOR_SLOT == ERX_BACKEND_PARK_NO_SLOT, "what erx_executor_slot answers on a worker");

typedef struct irq_object {
	bool		used;
	bool		bound;
	uint64_t	label;
} irq_object_t;

static void group_lock(void *);
static void group_unlock(void *);
static bool group_down(void *, uint32_t, uint64_t);
static void group_absorb(void *, uint32_t);
static void group_up(void *, uint32_t);

static const erx_backend_park_effects_t group_effects = { .lock = group_lock, .unlock = group_unlock,
    .down = group_down, .absorb = group_absorb, .up = group_up };
static _Alignas(ERX_PAGE_SIZE) erx_group_stat_t group_status;
static erx_backend_park_group_t group = { .status = &group_status };
static pthread_mutex_t group_mutex = PTHREAD_MUTEX_INITIALIZER;
/* A slot's semaphore holds 0 whenever its executor enters a park, and an exit leaves it there. */
static _Atomic uint32_t group_semaphores[ERX_GROUP_EXECUTORS_MAX];

static pthread_mutex_t irq_mutex = PTHREAD_MUTEX_INITIALIZER;
static irq_object_t irq_objects[ERX_BACKEND_PARK_OBJECTS_MAX];

static void
group_lock(void *context)
{
	(void)context;
	(void)pthread_mutex_lock(&group_mutex);
}

static void
group_unlock(void *context)
{
	(void)context;
	(void)pthread_mutex_unlock(&group_mutex);
}

static bool
group_down(void *context, uint32_t slot, uint64_t deadline)
{
	(void)context;
	return (erx_hosted_semaphore_down(&group_semaphores[slot], deadline));
}

static void
group_absorb(void *context, uint32_t slot)
{
	(void)context;
	(void)erx_hosted_semaphore_down(&group_semaphores[slot], ERX_WAIT_FOREVER);
}

static void
group_up(void *context, uint32_t slot)
{
	(void)context;
	erx_hosted_semaphore_up(&group_semaphores[slot]);
}

uint32_t
erx_hosted_executor_claim(void)
{
	return (erx_backend_park_claim(&group, &group_effects, NULL));
}

void
erx_hosted_executor_release(uint32_t slot)
{
	erx_backend_park_release(&group, &group_effects, NULL, slot);
}

const erx_group_stat_t *
erx_group_status(void)
{
	return (&group_status);
}

void
erx_group_trigger(void)
{
	erx_backend_park_trigger(&group, &group_effects, NULL);
}

int
erx_park(uint64_t group_epoch, uint64_t slot_epoch, uint64_t deadline)
{
	const uint32_t slot = erx_executor_slot();

	if (slot == ERX_NO_EXECUTOR_SLOT)
		return (ERX_ETYPE);
	return (erx_backend_park_wait(&group, &group_effects, NULL, slot, group_epoch, slot_epoch, deadline));
}

int
erx_executor_wake(uint32_t slot)
{
	return (erx_backend_park_wake(&group, &group_effects, NULL, slot));
}

/* The object a handle names, or NULL. Under irq_mutex. */
static irq_object_t *
irq_find(uint64_t irq)
{
	if (irq < IRQ_HANDLE_BASE || irq - IRQ_HANDLE_BASE >= ERX_BACKEND_PARK_OBJECTS_MAX)
		return (NULL);
	return (irq_objects[irq - IRQ_HANDLE_BASE].used ? &irq_objects[irq - IRQ_HANDLE_BASE] : NULL);
}

int
erx_irq_create(uint64_t budget, uint64_t resource, uint32_t kind, uint64_t selector, uint64_t *irq)
{
	int status = ERX_ENOMEM;

	(void)budget;
	(void)resource;
	(void)selector;
	if (kind == ERX_IRQ_LINE || kind == ERX_IRQ_MSI)
		return (ERX_ENOTSUP);
	if (kind != ERX_IRQ_SOFT)
		return (ERX_EINVAL);
	(void)pthread_mutex_lock(&irq_mutex);
	for (uint32_t index = 0; index < ERX_BACKEND_PARK_OBJECTS_MAX && status != ERX_OK; index++) {
		if (!irq_objects[index].used) {
			irq_objects[index] = (irq_object_t){ .used = true };
			*irq = IRQ_HANDLE_BASE + index;
			status = ERX_OK;
		}
	}
	(void)pthread_mutex_unlock(&irq_mutex);
	return (status);
}

int
erx_irq_bind(uint64_t irq, uint64_t group_handle, uint64_t label)
{
	irq_object_t *object;
	int status = ERX_EINVAL;

	(void)pthread_mutex_lock(&irq_mutex);
	object = irq_find(irq);
	if (object != NULL) {
		object->bound = group_handle != ERX_CAP_NULL;
		object->label = label;
		status = ERX_OK;
	}
	(void)pthread_mutex_unlock(&irq_mutex);
	return (status);
}

int
erx_irq_trigger(uint64_t irq)
{
	irq_object_t *object;
	bool bound;

	(void)pthread_mutex_lock(&irq_mutex);
	object = irq_find(irq);
	bound = object != NULL && object->bound;
	(void)pthread_mutex_unlock(&irq_mutex);
	if (object == NULL)
		return (ERX_EINVAL);
	if (!bound)
		return (ERX_OK);
	return (erx_backend_park_signal(&group, &group_effects, NULL, (uint32_t)(irq - IRQ_HANDLE_BASE)));
}

/* A software object has no line to unmask: an ack only checks its handle. */
int
erx_irq_ack(uint64_t irq)
{
	irq_object_t *object;

	(void)pthread_mutex_lock(&irq_mutex);
	object = irq_find(irq);
	(void)pthread_mutex_unlock(&irq_mutex);
	return (object != NULL ? ERX_OK : ERX_EINVAL);
}

int
erx_group_take_ready(uint32_t max)
{
	uint32_t objects[ERX_MSG_WORDS];
	erx_utcb_t *const utcb = erx_utcb_self();
	uint32_t taken;

	if (erx_executor_slot() == ERX_NO_EXECUTOR_SLOT)
		return (ERX_ETYPE);
	taken = erx_backend_park_take(&group, &group_effects, NULL, max < ERX_MSG_WORDS ? max : ERX_MSG_WORDS, objects);
	(void)pthread_mutex_lock(&irq_mutex);
	for (uint32_t index = 0; index < taken; index++)
		erx_utcb_mr_store(utcb, index, irq_objects[objects[index]].label);
	(void)pthread_mutex_unlock(&irq_mutex);
	return ((int)taken);
}
