/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

#ifndef ERX_BACKEND_API_H
#define ERX_BACKEND_API_H

#include <stdint.h>

#include "erx/abi.h"
#include "erx/cdefs.h"

/*
 * The function API of the kernel interface, as liberx's Phase 1 backends give it
 * (docs/design-stopgap.md, "The call table"): the same names, the same results and
 * the same refusals on native Fiasco and in a macOS process, which
 * test/guest/function_api holds them to. A handle is opaque, and an address is a
 * value of the caller's own space.
 */

/* A deadline meaning none. Deadlines are absolute monotonic nanoseconds, as erx_clock_ns reads them. */
#define ERX_WAIT_FOREVER	UINT64_MAX
/* What erx_executor_slot answers on a worker. */
#define ERX_NO_EXECUTOR_SLOT	UINT32_MAX

/* What erx_thread_create reads from the head of the caller's UTCB's mr. */
typedef struct erx_thread_start {
	erx_regs_t	regs;
	uint64_t	tls;
} erx_thread_start_t;

/*
 * Memory, in space: ERX_CAP_SELF, or a space the caller created, and any other value
 * is ERX_EINVAL; hosted, which makes no spaces, takes ERX_CAP_SELF alone. ERX_ENOMEM
 * from the pool, with no free range, or with the space's runs full; a refused call
 * changes nothing. Commit and decommit pass over holes, and a protect that meets one
 * is ERX_ERANGE. Write with execute is ERX_EINVAL. A commit or decommit that meets a
 * mapping, or a release that cuts one, is ERX_EINVAL, a protect that meets one
 * ERX_ENOTSUP; a release over a whole mapping removes it.
 */
int	erx_vm_reserve(uint64_t space, uint64_t addr, uint64_t size, uint32_t flags, uint64_t *reserved) ERX_WARN_UNUSED_RESULT;
int	erx_vm_commit(uint64_t space, uint64_t addr, uint64_t size) ERX_WARN_UNUSED_RESULT;
int	erx_vm_decommit(uint64_t space, uint64_t addr, uint64_t size) ERX_WARN_UNUSED_RESULT;
int	erx_vm_release(uint64_t space, uint64_t addr, uint64_t size) ERX_WARN_UNUSED_RESULT;
int	erx_space_protect(uint64_t space, uint64_t addr, uint64_t size, uint32_t prot) ERX_WARN_UNUSED_RESULT;
/* How many more pages can be committed, each exactly one page's worth. */
uint64_t erx_vm_free_pages(void);

/*
 * Threads. The starting registers are in the caller's UTCB: gpr[0] is the entry's
 * argument, and the entry never returns. Space 0 is the caller's own, the only one;
 * budget and group are ignored, and an executor takes a slot in the one group. No
 * free index, or no free slot, is ERX_ENOMEM.
 */
int	erx_thread_create(uint64_t budget, uint64_t space, uint64_t group, uint64_t thread_class,
	    uint64_t *thread) ERX_WARN_UNUSED_RESULT;
/* Starting a thread twice, or a handle that names none, is ERX_EINVAL. */
int	erx_thread_start(uint64_t thread) ERX_WARN_UNUSED_RESULT;
/* An empty mask, one that names no CPU, or a handle that names no thread is ERX_EINVAL. */
int	erx_thread_set_affinity(uint64_t thread, uint64_t mask) ERX_WARN_UNUSED_RESULT;
/* The word set to 0 and woken once the thread can no longer run. A bad handle is ERX_EINVAL. */
int	erx_thread_set_clear_word(uint64_t thread, uint64_t word) ERX_WARN_UNUSED_RESULT;
_Noreturn void	erx_thread_exit(void);
/* The same for a detached thread, whose stack is this range: it is released once the thread is gone. */
_Noreturn void	erx_thread_exit_release(uint64_t base, uint64_t size);
/* The value erx_thread_create's start record gave as tls. */
uint64_t	erx_thread_pointer(void);
erx_utcb_t	*erx_utcb_self(void);

/* Refused on both backends, whatever the arguments: ERX_ENOTSUP. */
int	erx_thread_stop(uint64_t thread) ERX_WARN_UNUSED_RESULT;
int	erx_thread_read(uint64_t thread) ERX_WARN_UNUSED_RESULT;
int	erx_thread_write(uint64_t thread) ERX_WARN_UNUSED_RESULT;
int	erx_thread_set_urgency(uint64_t thread, uint64_t urgency) ERX_WARN_UNUSED_RESULT;
int	erx_irq_route(uint64_t irq, uint64_t cpu) ERX_WARN_UNUSED_RESULT;
/* No gate carries a message (docs/design-stopgap.md, "IPC gates and where transfer fits"). */
int	erx_ipc_call(uint64_t gate, uint64_t tag, uint64_t send_by, uint64_t reply_by) ERX_WARN_UNUSED_RESULT;
int	erx_ipc_send(uint64_t gate, uint64_t tag, uint64_t send_by) ERX_WARN_UNUSED_RESULT;
int	erx_ipc_reply(uint64_t tag) ERX_WARN_UNUSED_RESULT;
int	erx_ipc_reply_wait(uint64_t tag, uint64_t wait_by) ERX_WARN_UNUSED_RESULT;

/* Waits. Correct within a space. A wake that finds no waiter counts none. */
int	erx_umtx_wait(uint64_t addr, uint32_t expected, uint64_t deadline);
/* How many it woke. */
int	erx_umtx_wake(uint64_t addr, uint32_t count);
/* Monotonic nanoseconds: a thread's later read is never below its earlier one, on any CPU. */
uint64_t	erx_clock_ns(void);

/* The deadline ns from now. One too far to add to the clock is no deadline. */
static inline uint64_t
erx_deadline_after(uint64_t ns)
{
	uint64_t deadline;

	return (__builtin_add_overflow(erx_clock_ns(), ns, &deadline) ? ERX_WAIT_FOREVER : deadline);
}

/*
 * The space's one group of executors. Read the epochs from the status page before
 * the empty check. A worker's park is ERX_ETYPE; ERX_OK when woken or an epoch
 * moved, ERX_ETIMEDOUT at the deadline.
 */
int	erx_park(uint64_t group_epoch, uint64_t slot_epoch, uint64_t deadline) ERX_WARN_UNUSED_RESULT;
/* An empty slot is ERX_EINVAL. */
int	erx_executor_wake(uint32_t slot) ERX_WARN_UNUSED_RESULT;
const erx_group_stat_t *erx_group_status(void);
/*
 * The group's grant, an erx_share_t in the caller's UTCB, of which only the CPU set is
 * kept: an empty one is ERX_EINVAL. The group is ERX_CAP_SELF or what erx_group_create
 * returned, and anything else is ERX_EINVAL.
 */
int	erx_group_configure(uint64_t group) ERX_WARN_UNUSED_RESULT;
/* Writes an erx_info_group_t to the caller's UTCB; a clear bit of its reported field disowns that field. */
int	erx_group_info(uint64_t group) ERX_WARN_UNUSED_RESULT;
/* The caller's slot in the group, or ERX_NO_EXECUTOR_SLOT. */
uint32_t	erx_executor_slot(void);
/* What an object's delivery runs: the epoch advances and the longest parked wakes. */
void	erx_group_trigger(void);

/*
 * IRQ objects. ERX_IRQ_SOFT alone is software's. The group is ERX_CAP_SELF or what
 * erx_group_create gave; a bind moves the object's label to the group, and a bind to
 * ERX_CAP_NULL unbinds it and masks a line, which unbinding again leaves as it is. No
 * object delivers while unbound and no trigger waits; a software object's fire while
 * unbound is owed to the next bind on Fiasco, as on erXos's kernel, and dropped hosted,
 * so a sink treats any delivery as a hint. A delivery carries the label bound when it
 * is taken, so an object that fired and was then unbound delivers label 0.
 */
int	erx_irq_create(uint64_t budget, uint64_t resource, uint32_t kind, uint64_t selector,
	    uint64_t *irq) ERX_WARN_UNUSED_RESULT;
int	erx_irq_bind(uint64_t irq, uint64_t group, uint64_t label) ERX_WARN_UNUSED_RESULT;
int	erx_irq_trigger(uint64_t irq) ERX_WARN_UNUSED_RESULT;
int	erx_irq_ack(uint64_t irq) ERX_WARN_UNUSED_RESULT;
/*
 * Takes up to max labels, at most ERX_MSG_WORDS, into the caller's UTCB's mr, each
 * label once however often its object fired. How many, or ERX_ETYPE on a worker.
 */
int	erx_group_take_ready(uint32_t max) ERX_WARN_UNUSED_RESULT;

/*
 * Devices' memory. A device's registers, by physical address, with the only attribute
 * ERX_MEM_ATTR_DEVICE; a run of memory a device can address, of at most
 * ERX_MEM_CONTIGUOUS_MAX bytes, aligned to its size rounded up to a power of two and
 * wholly below device address limit, 0 for none. resource is ignored; natively budget charges the object as
 * for every create (liberx/backend/fiasco/service.h), and hosted ignores it. Malformed
 * arguments are ERX_EINVAL on both backends, and hosted, which has no devices, refuses a
 * well-formed create with ERX_ENOTSUP. erx_mem_dma_addr gives the address a device uses: a
 * handle naming no object is ERX_EINVAL, as every handle is hosted, another kind of object
 * ERX_ETYPE, and an offset past the end ERX_ERANGE.
 */
int	erx_mem_create_physical(uint64_t budget, uint64_t resource, uint64_t base, uint64_t size, uint32_t attr,
	    uint64_t *mem) ERX_WARN_UNUSED_RESULT;
int	erx_mem_create_contiguous(uint64_t budget, uint64_t resource, uint64_t size, uint64_t limit,
	    uint64_t *mem) ERX_WARN_UNUSED_RESULT;
int	erx_mem_dma_addr(uint64_t mem, uint64_t offset, uint64_t *addr) ERX_WARN_UNUSED_RESULT;
/*
 * Maps part of a memory object at reserved addresses of space, which hold neither a
 * committed page nor a mapping (else ERX_EINVAL), in ERX_CAP_SELF or a space the
 * caller created. The mapping keeps the object until a release removes it or the
 * object goes, which removes every mapping of it at once. Hosted, where no handle
 * names an object a caller can map, every call is ERX_EINVAL.
 */
int	erx_vm_map(uint64_t space, uint64_t addr, uint64_t size, uint64_t mem, uint64_t offset, uint32_t prot) ERX_WARN_UNUSED_RESULT;

/*
 * Entropy: at most ERX_ENTROPY_BYTES_MAX bytes a call, at the head of the caller's UTCB's
 * mr, packed from each word's low byte. A read touches no byte past len. More bytes, or an
 * unknown flag, is ERX_EINVAL, and ERX_ENTROPY_CREDIT is ERX_ENOTSUP, since no source is
 * trusted. What the bytes are worth natively, the root's banner line says. res is ignored.
 */
int	erx_entropy_read(uint32_t len) ERX_WARN_UNUSED_RESULT;
int	erx_entropy_add(uint64_t res, uint32_t len, uint32_t flags) ERX_WARN_UNUSED_RESULT;

/*
 * What one erx_log_read did: where the next read starts, how many records were overwritten
 * before anyone read them, and how many bytes at the window's start are whole records.
 */
typedef struct erx_log_read_result {
	uint64_t	next_cursor;
	uint64_t	lost;
	uint64_t	written;
} erx_log_read_result_t;

/*
 * The kernel log's reader (docs/design-stopgap.md, "The console"): copies whole records that
 * nobody has taken, from cursor on, into the window of size bytes, which holds at least
 * ERX_LOG_RECORD_MAX, and counts them as taken. Every read moves the one position of what
 * has been taken, the console's too, so a record leaves exactly once and the log has one
 * reader, the system domain's console. The window is the caller's own memory, which the
 * service writes in place, so natively only the root reads; a task is ERX_ENOTSUP. A short
 * window, or a cursor past what has been taken, is ERX_EINVAL. res is ignored.
 */
int	erx_log_read(uint64_t res, uint64_t cursor, void *window, uint64_t size,
	    erx_log_read_result_t *result) ERX_WARN_UNUSED_RESULT;

/*
 * A kernel object's report (docs/design-stopgap.md, "Reporting kernel objects"): writes
 * the topic's erx_info_<kind> into the window of size bytes, the caller's own memory.
 * Machine and cpu ignore object; group takes ERX_CAP_SELF or what erx_group_create
 * returned, budget ERX_CAP_SELF, the root's one budget, and thread ERX_CAP_SELF or a
 * space erx_space_create returned; any other handle is ERX_ENOTSUP. Natively every
 * topic but group is the root's alone, and a task's call ERX_ENOTSUP. basic and image
 * entry are ERX_ENOTSUP; a CPU off the map or a thread index past the last is
 * ERX_ERANGE, which ends a listing. A clear reported bit disowns its field. It stands
 * for the kernel call until abi/erx_abi.txt can declare a capability of any type.
 */
int	erx_object_info(uint64_t object, uint32_t topic, uint64_t index, void *window, uint64_t size)
	    ERX_WARN_UNUSED_RESULT;
/*
 * The fields of a topic's report that the backend counts only partly, as reported bits
 * whose bits in the report itself stay clear: a budget's used, from the pool's count.
 * The inspector shows them as partial, under the stopgap reporter the schema lists. On
 * erXos's kernel it is 0.
 */
uint32_t	erx_info_partial(uint32_t topic);

/*
 * What one trace read did: where the next read starts, how many records it copied, and how
 * many records between the cursor and next were overwritten before they were read.
 */
typedef struct erx_trace_read_result {
	uint64_t	next;
	uint64_t	kept;
	uint64_t	overwritten;
} erx_trace_read_result_t;

/*
 * The root's trace ring (docs/design-stopgap.md, "The trace ring"): copies at most max of the
 * whole records from cursor on into records[0 .. kept) and takes no lock. max and records
 * are checked first, whatever the cursor. A cursor of UINT64_MAX copies nothing and returns the ring's head as next. Any other cursor past the
 * head, or max 0 or over ERX_TRACE_READ_MAX, is ERX_EINVAL; a cursor at the head of an
 * exhausted ring is ERX_ELIMIT. A cursor more than ERX_TRACE_RING_RECORDS below the head
 * starts that far below it, and the records it skips count as overwritten. In a task, which
 * has no ring, ERX_ENOTSUP.
 */
int	erx_backend_trace_read(uint64_t cursor, erx_trace_record_t *records, uint32_t max,
	    erx_trace_read_result_t *result) ERX_WARN_UNUSED_RESULT;

/*
 * The kernel's per-CPU trace rings (docs/design-kernel.md, "Trace ring"), with the same
 * cursor and records as erx_backend_trace_read. The stopgap has no kernel ring: ERX_ENOTSUP
 * on both backends, so the trace's kernel row is unsupported.
 */
int	erx_trace_read(uint64_t res, uint32_t cpu, uint64_t cursor, erx_trace_record_t *records,
	    uint32_t max, erx_trace_read_result_t *result) ERX_WARN_UNUSED_RESULT;

/* how is ERX_END_OFF or ERX_END_RESET, and res is ignored. Returns only on a refusal. */
int	erx_machine_end(uint64_t res, uint32_t how);

/* Tells the machine's watchdog that the caller's schedulers run. A store, and takes no lock. */
int	erx_watchdog_pet(void) ERX_WARN_UNUSED_RESULT;

#endif /* ERX_BACKEND_API_H */
