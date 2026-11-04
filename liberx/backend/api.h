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
 * Memory. ERX_ENOMEM from the pool, with no free range, or with the space's runs
 * full; a refused call changes nothing. Commit and decommit pass over holes, and
 * a protect that meets one is ERX_ERANGE. Write with execute is ERX_EINVAL.
 */
int	erx_vm_reserve(uint64_t addr, uint64_t size, uint32_t flags, uint64_t *reserved) ERX_WARN_UNUSED_RESULT;
int	erx_vm_commit(uint64_t addr, uint64_t size) ERX_WARN_UNUSED_RESULT;
int	erx_vm_decommit(uint64_t addr, uint64_t size) ERX_WARN_UNUSED_RESULT;
int	erx_vm_release(uint64_t addr, uint64_t size) ERX_WARN_UNUSED_RESULT;
int	erx_space_protect(uint64_t addr, uint64_t size, uint32_t prot) ERX_WARN_UNUSED_RESULT;
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

/* Waits. Correct within a space. A wake that finds no waiter counts none. */
int	erx_umtx_wait(uint64_t addr, uint32_t expected, uint64_t deadline);
/* How many it woke. */
int	erx_umtx_wake(uint64_t addr, uint32_t count);
uint64_t	erx_clock_ns(void);

/*
 * The space's one group of executors. Read the epochs from the status page before
 * the empty check. A worker's park is ERX_ETYPE; ERX_OK when woken or an epoch
 * moved, ERX_ETIMEDOUT at the deadline.
 */
int	erx_park(uint64_t group_epoch, uint64_t slot_epoch, uint64_t deadline) ERX_WARN_UNUSED_RESULT;
/* An empty slot is ERX_EINVAL. */
int	erx_executor_wake(uint32_t slot) ERX_WARN_UNUSED_RESULT;
const erx_group_stat_t *erx_group_status(void);
/* The caller's slot in the group, or ERX_NO_EXECUTOR_SLOT. */
uint32_t	erx_executor_slot(void);
/* What an object's delivery runs: the epoch advances and the longest parked wakes. */
void	erx_group_trigger(void);

/*
 * IRQ objects. ERX_IRQ_SOFT alone is software's; a bind moves the object's label to
 * the group, and a bind to ERX_CAP_NULL unbinds it. A trigger of an object not bound
 * delivers nothing and never waits. A delivery carries the label bound when it is
 * taken, so an object that fired and was then unbound delivers label 0.
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
 * wholly below device address limit, 0 for none. budget and resource are ignored. Malformed
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
 * Entropy: at most ERX_ENTROPY_BYTES_MAX bytes a call, at the head of the caller's UTCB's
 * mr, packed from each word's low byte. A read touches no byte past len. More bytes, or an
 * unknown flag, is ERX_EINVAL, and ERX_ENTROPY_CREDIT is ERX_ENOTSUP, since no source is
 * trusted. What the bytes are worth natively, the root's banner line says. res is ignored.
 */
int	erx_entropy_read(uint32_t len) ERX_WARN_UNUSED_RESULT;
int	erx_entropy_add(uint64_t res, uint32_t len, uint32_t flags) ERX_WARN_UNUSED_RESULT;

/* how is ERX_END_OFF or ERX_END_RESET, and res is ignored. Returns only on a refusal. */
int	erx_machine_end(uint64_t res, uint32_t how);

#endif /* ERX_BACKEND_API_H */
