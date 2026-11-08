/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

#ifndef ERX_FIASCO_SERVICE_H
#define ERX_FIASCO_SERVICE_H

#include <stddef.h>
#include <stdint.h>

#include "erx/abi.h"
#include "erx/cdefs.h"
#include "erx/core/crash.h"
#include "erx/watchdog.h"

/*
 * The root service (docs/design-stopgap.md, "The root service"): one thread that
 * owns the root's tables and receives every request and every fault of the root's
 * threads through one gate.
 */

/*
 * The root's first steps, on its first thread: maps its image, touches each page
 * of the archive so it maps read-only, builds the pool and thread table, starts
 * the service and makes it this thread's pager. From its return every fault of a
 * root thread ends the machine. Returns NULL, or why the boot cannot go on.
 */
const char	*erx_fiasco_root_up(const void *archive, size_t archive_bytes);
/* The CPUs the kernel reports online, as a mask. */
uint64_t	 erx_fiasco_cpus_online(void);

/*
 * Sends one request of bytes to the service and waits for its reply. Returns the
 * reply's status, with *reply holding the rest.
 */
uint64_t	erx_fiasco_service_gate(void);
/* In the root, the capability that names a task's space. */
uint64_t	erx_fiasco_task_cap(uint32_t task);
/* In the root, the semaphore a task's end ups, for the launcher's wait. */
uint64_t	erx_fiasco_task_ended_cap(uint64_t task);
/* In the root, the service thread, which every gate is bound to. */
uint64_t	erx_fiasco_service_thread(void);

/*
 * Task calls of the call table. fault is ERX_CAP_NULL or a gate the caller holds,
 * else ERX_ETYPE, and the space's records go to it with label as their label;
 * parent and budget are accepted and ignored; cap_limit bounds the task's handle table, counting ERX_CAP_NULL as erXos's
 * kernel does, and outside 2 to ERX_CAPS_MAX is ERX_EINVAL; only the root makes a task. image is ignored and entry is the boot
 * archive's; *start is where the task's first thread will start. A task stops itself
 * with ERX_CAP_SELF, and on success that call does not return; the root may stop a task.
 */
int	erx_space_create(uint64_t budget, uint64_t parent, uint64_t fault, uint64_t label, uint32_t flags,
	    uint32_t cap_limit, uint64_t *space) ERX_WARN_UNUSED_RESULT;
int	erx_image_map(uint64_t space, uint64_t image, uint64_t entry, uint64_t *start) ERX_WARN_UNUSED_RESULT;
int	erx_space_stop(uint64_t space, int64_t status);

/*
 * Handle calls (docs/design-stopgap.md, "Capabilities in Fiasco's object space"): a
 * handle that is no entry in use is ERX_EINVAL, one whose object has gone ERX_ESTALE.
 * A dup into a full table is ERX_ELIMIT. A close frees the entry, a stale one too,
 * and the object goes with its last handle unless it is mapped. A destroy from a task
 * other than the object's creator's is ERX_ERIGHTS, and of a mapped object
 * ERX_ENOTSUP; the handles to a destroyed object stay, answering ERX_ESTALE.
 */
int	erx_cap_dup(uint64_t cap, uint64_t *copy) ERX_WARN_UNUSED_RESULT;
int	erx_cap_close(uint64_t cap) ERX_WARN_UNUSED_RESULT;
int	erx_object_destroy(uint64_t object) ERX_WARN_UNUSED_RESULT;

/*
 * Fault gates (docs/design-stopgap.md, "Fault gates"): a gate carries the fault and
 * exit records of the spaces made naming it, and nothing else. budget is ignored. A
 * bind's thread is ERX_CAP_SELF_THREAD or a handle of one of the caller's own
 * threads, another task's ERX_ENOTSUP; ERX_CAP_NULL unbinds, and a bind replaces the
 * thread bound before. label is ignored: a record's label is its space's. A destroy
 * drops the gate's records and leaves its spaces with no gate, whose later records
 * are dropped. erx_ipc_wait takes the oldest record of the gates bound to the
 * calling thread into the head of its UTCB's mr, an erx_fault_t, and its label into
 * *label, or waits for one until the deadline, ERX_ETIMEDOUT; a thread no gate is
 * bound to waits for its deadline.
 */
int	erx_gate_create(uint64_t budget, uint64_t *gate) ERX_WARN_UNUSED_RESULT;
int	erx_gate_bind(uint64_t gate, uint64_t thread, uint64_t label) ERX_WARN_UNUSED_RESULT;
int	erx_ipc_wait(uint64_t deadline, uint64_t *label) ERX_WARN_UNUSED_RESULT;
int	erx_fiasco_service_call(uint32_t number, const void *request, size_t bytes,
	    erx_fiasco_reply_t *reply);

/*
 * A task's standard output and standard error: the service writes these bytes to the
 * console unchanged, one call per ERX_UTCB_BYTES_MAX. Like the console, it drops what
 * it cannot deliver: a write's result never depends on it.
 */
void	erx_fiasco_task_write(const void *bytes, size_t length);
/* The manifest's console UART, whose create hands the debug log to its reader. 0 is none. */
void	erx_fiasco_task_console_set(uint64_t base);

/* how is ERX_END_OFF or ERX_END_RESET; res is ignored. Returns only on a refusal. */
int	erx_machine_end(uint64_t res, uint32_t how);

/*
 * The end path (docs/design-stopgap.md, "The end path"): the first caller wins
 * and the rest sleep. With a fault it first prints the crash frame. Takes no lock.
 */
_Noreturn void	erx_fiasco_end(const erx_crash_fault_t *fault, uint32_t how);
/* The same for a missed pet, on the watchdog's own thread. */
_Noreturn void	erx_fiasco_end_watchdog(const erx_watchdog_end_t *end);
/* A task's fault: its crash frame on the console, with the machine going on. Only the service calls it. */
void	erx_fiasco_task_crash_write(const erx_crash_fault_t *fault);

#ifdef ERX_FIASCO_TEST_HOOKS
#include <stdatomic.h>
#include <stdbool.h>

/* See service.c: the start step to fail, and whether a thread's capabilities are gone. */
extern _Atomic uint32_t erx_fiasco_test_start_fails;
bool erx_fiasco_test_thread_caps_gone(uint32_t);
bool erx_fiasco_test_task_caps_gone(uint32_t);
uint64_t erx_fiasco_test_dropped(void);
uint32_t erx_fiasco_test_cpu_count(void);
int erx_fiasco_test_thread_priority(uint32_t, uint32_t, uint64_t);
#endif

#endif /* ERX_FIASCO_SERVICE_H */
