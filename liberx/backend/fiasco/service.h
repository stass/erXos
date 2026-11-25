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
#include "erx/core/dt.h"
#include "erx/release.h"
#include "erx/watchdog.h"
#include "liberx/backend/fiasco/end_how.h"
#include "liberx/backend/fiasco/entropy.h"

/*
 * The root service (docs/design-fiasco.md, "The root service"): one thread that
 * owns the root's tables and receives every request and every fault of the root's
 * threads through one gate.
 */

/*
 * The quantum of a root that reads no manifest: a slice the manifest reader would take, one of
 * Fiasco's 1 ms scheduler ticks.
 */
#define ERX_FIASCO_ROOT_SLICE_US 1000
_Static_assert(ERX_FIASCO_ROOT_SLICE_US >= ERX_SLICE_MIN_US && ERX_FIASCO_ROOT_SLICE_US <= ERX_SLICE_MAX_US,
    "a root that reads no manifest takes a slice the manifest reader would take");

/*
 * The root's first steps, on its first thread: maps its image, touches each page
 * of the archive so it maps read-only, builds the pool and thread table, starts
 * the service and makes it this thread's pager. From its return every fault of a
 * root thread ends the machine. dma_bytes is the devices' memory the root will
 * make, which sizes the contiguous pool (erx_fiasco_vm_init): the manifest's total
 * for the program root, a test's own figure for a native test root. seeds are
 * what the tree gave (erx_fiasco_program_tree), which the generator mixes in, or NULL
 * for a root that reads no tree; they stay the caller's to erase. slice_us is the quantum of
 * the root's own threads, the service's included: the manifest's system share's slice for the
 * program root, which the manifest reader holds to ERX_SLICE_MIN_US .. ERX_SLICE_MAX_US, and
 * ERX_FIASCO_ROOT_SLICE_US for a root that reads no manifest. Returns NULL, or why the boot
 * cannot go on.
 */
const char	*erx_fiasco_root_up(const void *archive, size_t archive_bytes, uint64_t dma_bytes,
	    const erx_fiasco_seeds_t *seeds, uint32_t slice_us);
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
/* In the root, the service thread, which every gate is bound to. */
uint64_t	erx_fiasco_service_thread(void);

/*
 * Task calls of the call table. fault is a gate the caller holds, or ERX_CAP_NULL in the
 * launcher's test create alone, else the lookup's refusal (ERX_ESTALE for a value that
 * names nothing, ERX_CAP_NULL among them, ERX_ETYPE for another kind), and the space's records go to it with label as their label; parent
 * is ERX_CAP_SELF or a space the caller created, else the lookup's refusal, and one
 * that is stopping is ERX_EINVAL; the new space joins parent's tree and stops when
 * parent stops; budget charges the space as for every create
 * (erx_budget_create below); cap_limit bounds the task's handle table, counting ERX_CAP_NULL as erXos's
 * kernel does, and outside 2 to ERX_CAPS_MAX, or past ERX_FIASCO_CAP_LIMIT_MAX, whose window of
 * IRQ slots would pass Fiasco's object space, is ERX_EINVAL; with the task table or the root's
 * slot pool full the create is ERX_ENOMEM; any task makes a task below its own
 * space or one it created. erx_image_map loads into a space the caller created: image is
 * 0, the whole boot archive, from the root alone, or a slice the caller holds, and entry
 * is an index in it; *start is where the task's first thread will start. A task stops
 * itself with ERX_CAP_SELF, and on success that call does not return; a holder of a
 * space's handle may stop it.
 */
int	erx_space_create(uint64_t budget, uint64_t parent, uint64_t fault, uint64_t label, uint32_t flags,
	    uint32_t cap_limit, uint64_t *space) ERX_WARN_UNUSED_RESULT;
int	erx_image_map(uint64_t space, uint64_t image, uint64_t entry, uint64_t *start) ERX_WARN_UNUSED_RESULT;
/*
 * What erx_image_map checks in the calling thread before its request: in the root
 * (slice.c), an image entry named by archive index has its file checked once, so the
 * service, which maps it only with a good verdict, never hashes it; ERX_ECORRUPT for a
 * damaged file, ERX_OK otherwise. A task holds no archive, and its own is always ERX_OK
 * (task_start.c): the service refuses an archive index from a task, and a slice holds
 * no image entry.
 */
int	erx_fiasco_image_check(uint64_t image, uint64_t entry) ERX_WARN_UNUSED_RESULT;
int	erx_space_stop(uint64_t space, int64_t status);

/*
 * Slices and copies (docs/design-fiasco.md, "The call table"). erx_image_slice, from the
 * root alone, makes a memory object of entries [first, first + count) of the boot archive,
 * charged to budget; image is ignored, as this backend has the one image. A map of it is
 * read-only. erx_mem_copy copies len bytes between two memory objects the caller holds,
 * 64 pages a request: either gone ERX_ESTALE, a range past its object ERX_ERANGE, a
 * device's object ERX_ETYPE, a slice as dst ERX_ERIGHTS, each before any byte moves.
 * erx_fiasco_release_entry is a task's erx_release_entry over the slice release names, its
 * file checked first when check is set; with entry NULL only the check is made.
 * A paged object (erx_mem_create_paged) maps nowhere until sealed and is never mapped
 * writable; erx_mem_supply copies into it as erx_mem_copy does until erx_mem_seal, and
 * then ERX_ERIGHTS. Only the root makes one with ERX_MEM_CODE, the one that may run.
 * erx_mem_child copies size bytes of a slice or a sealed paged object from offset into
 * a new object charged to budget, which maps read and write and never to run: another
 * parent, a child's included, ERX_ETYPE; a size of 0 or a size or offset off a page
 * ERX_EINVAL; a range past the parent's end ERX_ERANGE; and the copy's refusals.
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
int	erx_mem_child(uint64_t parent, uint64_t budget, uint64_t offset, uint64_t size, uint64_t *child)
	    ERX_WARN_UNUSED_RESULT;

/*
 * Handle calls (docs/design-fiasco.md, "Capabilities in Fiasco's object space"): a
 * handle that names no entry in use at its generation, or whose object has gone, is
 * ERX_ESTALE. A dup into a full table is ERX_ELIMIT. A close frees the entry, a stale one too,
 * and the object goes with its last handle unless it is mapped. A destroy from a task
 * other than the object's creator's, or of an object the root keeps, is ERX_ERIGHTS,
 * and of a group that still has threads ERX_ENOTSUP; a destroy revokes every mapping
 * of the object, and the handles to a destroyed object stay, answering ERX_ESTALE.
 */
int	erx_cap_dup(uint64_t cap, uint64_t *copy) ERX_WARN_UNUSED_RESULT;
int	erx_cap_close(erx_cap_t cap) ERX_WARN_UNUSED_RESULT;
int	erx_object_destroy(uint64_t object) ERX_WARN_UNUSED_RESULT;

/*
 * Budgets as records (docs/design-fiasco.md, "Budgets and groups as records"). Only
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
 * erx_cap_pass (docs/design-fiasco.md, "Passing a handle"), the creator's case from
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
 * Fault gates (docs/design-fiasco.md, "Fault gates"): a gate carries the fault and
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

/* how is ERX_END_OFF or ERX_END_RESET; res is ignored. Returns only on a refusal. */
int	erx_machine_end(uint64_t res, uint32_t how);

/*
 * The end path (docs/design-fiasco.md, "The end path"): the first caller wins
 * and the rest sleep. With a fault, the root's, it first prints the crash frame; the
 * cause decides how the machine ends (erx_fiasco_end_how). Takes no lock.
 */
_Noreturn void	erx_fiasco_end(erx_fiasco_end_cause_t cause, const erx_crash_fault_t *fault);
/*
 * A refusal's end: line is a NUL-terminated fixed line of the root's own ending in a newline. On
 * the service thread, which owns the log, it follows the records the log still holds, so the
 * console shows them in the order written; on any other thread the ring is skipped, as at
 * every end off the service thread (end.c).
 */
_Noreturn void	erx_fiasco_end_refused(const char *line);
/* A refused boot's end, the same with the line "erx: root task refused the boot: REASON". */
_Noreturn void	erx_fiasco_end_boot_refused(const char *reason);
/* The same for a missed pet, on the watchdog's own thread. */
_Noreturn void	erx_fiasco_end_watchdog(const erx_watchdog_end_t *end);
/* Whether an end has been taken, after which the board's watchdog is written no more (erx_fiasco_pm_wdt_step). */
bool	erx_fiasco_end_taken(void);
/* A task's fault: its crash frame on the console, with the machine going on. Only the service calls it. */
void	erx_fiasco_task_crash_write(const erx_crash_fault_t *fault);

#ifdef ERX_FIASCO_TEST_HOOKS
#include <stdatomic.h>
#include <stdbool.h>

/*
 * See service.c and service_task.c: the start step to fail, whether a thread's capabilities
 * are gone, whether every free pair of the slot pool reads empty, and how many pairs are free.
 */
extern _Atomic uint32_t erx_fiasco_test_start_fails;
bool erx_fiasco_test_thread_caps_gone(uint32_t);
bool erx_fiasco_test_pool_slots_gone(void);
uint32_t erx_fiasco_test_pool_free(void);
uint64_t erx_fiasco_test_dropped(void);
/* Every message the service received: a direct ring or ack leaves it unchanged. */
uint64_t erx_fiasco_test_received(void);
/*
 * How many of a task's messages the decoder refused (erx_fiasco_wire_decode): the root's
 * for ERX_CAP_SELF, else the task a space handle of the root's names, until its join;
 * UINT64_MAX for a handle that names none.
 */
uint64_t erx_fiasco_test_refused(uint64_t space);
uint32_t erx_fiasco_test_cpu_count(void);
int erx_fiasco_test_thread_priority(uint32_t, uint32_t, uint64_t);
/*
 * The cheapest call Fiasco answers alone (docs/design-bench.md, "3. `nullcall`: the
 * decoder-refusal round trip"): an IPC call to the empty slot 0, which Fiasco answers
 * from its capability lookup without reaching an object (kernel/src/kern/syscalls.cpp,
 * sys_ipc_wrapper). Its result is Fiasco's IPC error, ERX_FIASCO_TEST_EMPTY_SLOT_ERROR
 * (l4sys's L4_IPC_ENOT_EXISTENT) for an empty slot.
 */
#define ERX_FIASCO_TEST_EMPTY_SLOT_ERROR	UINT64_C(4)
uint64_t erx_fiasco_test_empty_slot_call(void);
/*
 * Fiasco's answer to a UTCB area of 2^order bytes at address in the root's space: 0 when it
 * grants the area, ERX_FIASCO_TEST_KU_MEM_REFUSED (l4sys's -L4_EINVAL) when it refuses one
 * whose kernel alias could differ from the address in bits 12 and 13 (docs/design-fiasco.md,
 * "A congruent UTCB area").
 */
#define ERX_FIASCO_TEST_KU_MEM_REFUSED	INT64_C(-22)
int64_t erx_fiasco_test_ku_mem_add(uint64_t, unsigned);
#endif

#endif /* ERX_FIASCO_SERVICE_H */
