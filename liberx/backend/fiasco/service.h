/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

#ifndef ERX_FIASCO_SERVICE_H
#define ERX_FIASCO_SERVICE_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#include "erx/abi.h"
#include "erx/cdefs.h"
#include "erx/core/boot_handoff.h"
#include "erx/core/crash.h"
#include "erx/release.h"
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
/*
 * Keeps what bootstrap's handoff said of the machine, its build identifier and boot
 * value, for erx_object_info's machine report. It runs once, before
 * erx_fiasco_root_up starts the service thread that reads them, so they never
 * change under it. The program root calls it. A root that does not call it
 * reports neither: libc_root, and the native test guests, though they read a handoff.
 */
void		 erx_fiasco_service_boot(const erx_boot_handoff_view_t *handoff);
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
 * parent is accepted and ignored, and budget charges the space as for every create
 * (erx_budget_create below); cap_limit bounds the task's handle table, counting ERX_CAP_NULL as erXos's
 * kernel does, and outside 2 to ERX_CAPS_MAX is ERX_EINVAL; any task makes a task below its own
 * space or one it created. erx_image_map loads into a space the caller created: image is
 * 0, the whole boot archive, from the root alone, or a slice the caller holds, and entry
 * is an index in it; *start is where the task's first thread will start. A task stops
 * itself with ERX_CAP_SELF, and on success that call does not return; a holder of a
 * space's handle may stop it.
 */
int	erx_space_create(uint64_t budget, uint64_t parent, uint64_t fault, uint64_t label, uint32_t flags,
	    uint32_t cap_limit, uint64_t *space) ERX_WARN_UNUSED_RESULT;
int	erx_image_map(uint64_t space, uint64_t image, uint64_t entry, uint64_t *start) ERX_WARN_UNUSED_RESULT;
int	erx_space_stop(uint64_t space, int64_t status);

/*
 * Slices and copies (docs/design-stopgap.md, "The call table"). erx_image_slice, from the
 * root alone, makes a memory object of entries [first, first + count) of the boot archive,
 * charged to budget; image is ignored, as this backend has the one image. A map of it is
 * read-only. erx_mem_copy copies len bytes between two memory objects the caller holds,
 * 64 pages a request: either gone ERX_ESTALE, a range past its object ERX_ERANGE, a
 * device's object ERX_ETYPE, a slice as dst ERX_ERIGHTS, each before any byte moves.
 * erx_fiasco_release_entry is a task's erx_release_entry over the slice release names, its
 * file checked first when check is set; with entry NULL only the check is made.
 * Paged objects are not offered: their three calls are ERX_ENOTSUP.
 */
int	erx_image_slice(uint64_t budget, uint64_t image, uint64_t first, uint64_t count, uint64_t *slice)
	    ERX_WARN_UNUSED_RESULT;
int	erx_mem_copy(uint64_t dst, uint64_t dst_offset, uint64_t src, uint64_t src_offset, uint64_t len)
	    ERX_WARN_UNUSED_RESULT;
int	erx_fiasco_release_entry(uint64_t release, uint64_t index, bool check, erx_release_entry_t *entry)
	    ERX_WARN_UNUSED_RESULT;
int	erx_mem_create_paged(uint64_t budget, uint64_t size, uint32_t flags, uint64_t *mem) ERX_WARN_UNUSED_RESULT;
int	erx_mem_supply(uint64_t mem, uint64_t offset, uint64_t src, uint64_t src_offset, uint64_t len)
	    ERX_WARN_UNUSED_RESULT;
int	erx_mem_seal(uint64_t mem) ERX_WARN_UNUSED_RESULT;

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
 * Budgets as records (docs/design-stopgap.md, "Budgets and groups as records"). Only
 * the root carves and resizes; a task's call is ERX_ENOTSUP. A create makes a budget
 * under parent, ERX_CAP_SELF for the root's own or a budget the root holds, with kind
 * ERX_BUDGET_WALL or ERX_BUDGET_ELASTIC, else ERX_EINVAL, and guarantee and cap in pages,
 * recorded and never checked. A resize records the two values; the root's own budget
 * is resized by no one, ERX_ENOTSUP. A watch is ERX_ENOTSUP. A budget goes, at its
 * destroy or its last handle's close, with everything charged to it or to a budget
 * carved from it: its spaces stop and go, and every handle to any of it answers
 * ERX_ESTALE. Every create's budget is ERX_CAP_SELF or ERX_CAP_NULL for the budget
 * the caller's own space is charged to, or a budget handle the caller holds.
 */
int	erx_budget_create(uint64_t parent, uint32_t kind, uint64_t guarantee, uint64_t cap, uint64_t *budget)
	    ERX_WARN_UNUSED_RESULT;
int	erx_budget_resize(uint64_t budget, uint64_t guarantee, uint64_t cap) ERX_WARN_UNUSED_RESULT;
int	erx_budget_watch(uint64_t budget, uint64_t irq, uint64_t threshold) ERX_WARN_UNUSED_RESULT;

/*
 * erx_cap_pass (docs/design-stopgap.md, "Passing a handle"), the creator's case from
 * any task: from is ERX_CAP_SELF and to a live space the caller created. Its n
 * items, at most ERX_MSG_CAPS, are erx_msg_item_t in the calling thread's public UTCB,
 * each a copy or a move of one of the caller's handles with a rights mask. They pass in
 * order, each rewritten there with its value, type and rights in to's table; the first
 * refused stops the pass with its status, and the items before it stay passed for the
 * caller to undo. A call from another space, into the caller's own, or of a space or
 * gate handle is ERX_ENOTSUP.
 */
int	erx_cap_pass(uint64_t from, uint64_t to, uint32_t n) ERX_WARN_UNUSED_RESULT;

/*
 * Fault gates (docs/design-stopgap.md, "Fault gates"): a gate carries the fault and
 * exit records of the spaces made naming it, and nothing else. budget charges it as for every create. A
 * bind's thread is ERX_CAP_SELF_THREAD or a handle of one of the caller's own
 * threads, another task's ERX_ENOTSUP; ERX_CAP_NULL unbinds, and a bind replaces the
 * thread bound before. label is ignored: a record's label is its space's. A destroy
 * drops the gate's records and leaves its spaces with no gate, whose later records
 * are dropped. erx_ipc_wait takes the oldest record of the gates bound to the
 * calling thread into the head of its UTCB's mr, an erx_fault_t, its tag into *tag
 * (an erx_fault_t's words, no items, protocol 0) and its label into *label, or waits for one until the deadline, ERX_ETIMEDOUT; a thread no gate is
 * bound to waits for its deadline.
 */
int	erx_gate_create(uint64_t budget, uint64_t *gate) ERX_WARN_UNUSED_RESULT;
int	erx_gate_bind(uint64_t gate, uint64_t thread, uint64_t label) ERX_WARN_UNUSED_RESULT;
int	erx_ipc_wait(uint64_t wait_by, erx_msgtag_t *tag, uint64_t *label) ERX_WARN_UNUSED_RESULT;
int	erx_fiasco_service_call(uint32_t number, const void *request, size_t bytes,
	    erx_fiasco_reply_t *reply);

/*
 * A task's standard output and standard error: the service writes these bytes to the
 * console unchanged, one call per ERX_UTCB_BYTES_MAX. Like the console, it drops what
 * it cannot deliver: a write's result never depends on it.
 */
void	erx_fiasco_task_write(const void *bytes, size_t length);
/*
 * Stores length bytes, at most ERX_UTCB_BYTES_MAX, in the calling thread's public UTCB
 * message words, as erx_debug_log and task_write read them, the last word zero-padded.
 */
void	erx_fiasco_utcb_store_bytes(const void *bytes, size_t length);
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

/* See service.c: the start step to fail, and whether a thread's, or every unused task index's, capabilities are gone. */
extern _Atomic uint32_t erx_fiasco_test_start_fails;
bool erx_fiasco_test_thread_caps_gone(uint32_t);
bool erx_fiasco_test_task_caps_gone(void);
uint64_t erx_fiasco_test_dropped(void);
uint32_t erx_fiasco_test_cpu_count(void);
int erx_fiasco_test_thread_priority(uint32_t, uint32_t, uint64_t);
#endif

#endif /* ERX_FIASCO_SERVICE_H */
