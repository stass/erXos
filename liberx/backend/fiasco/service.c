/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

/*
 * The root service's thread: the root's first steps up to it, its loop, and the
 * calls' bodies. It runs each body to its end before the next receive, so what
 * only it touches needs no lock, and a body never sends a request. A fault is one
 * more message, never answered: every committed page is already mapped, so the
 * fault of a root thread ends the machine and a task's fault ends the task. The
 * service's own fault goes to sigma0, which repairs nothing: a recorded gap.
 */

#include <stdatomic.h>
#include <stddef.h>
#include <stdint.h>

#include <l4/sigma0/sigma0.h>
#include <l4/sys/consts.h>
#include <l4/sys/factory.h>
#include <l4/sys/ipc.h>
#include <l4/sys/scheduler.h>
#include <l4/sys/task.h>
#include <l4/sys/thread.h>
#include <l4/sys/utcb.h>

#include "erx/abi.h"
#include "liberx/backend/fiasco/console.h"
#include "liberx/backend/fiasco/entropy.h"
#include "liberx/backend/fiasco/group.h"
#include "liberx/backend/fiasco/service.h"
#include "liberx/backend/fiasco/service_task.h"
#include "liberx/backend/fiasco/service_wire.h"
#include "liberx/backend/fiasco/thread.h"
#include "liberx/backend/fiasco/time.h"
#include "liberx/backend/fiasco/vm.h"

#define SERVICE_STACK_BYTES	16384u
/* The default priority of every thread but the watchdog. */
#define SERVICE_THREAD_PRIORITY	1u
/* The task's part of another task's thread handle: a task's own handles are indices. */
#define SERVICE_HANDLE_TASK_SHIFT	8u
#define SERVICE_HANDLE_INDEX_MASK	((UINT64_C(1) << SERVICE_HANDLE_TASK_SHIFT) - 1)
/* A thread the fault cannot name. */
#define SERVICE_THREAD_UNKNOWN	UINT64_MAX
/* The fault word's low bits say how the page was touched. */
#define SERVICE_FAULT_ACCESS	UINT64_C(7)

_Static_assert(L4_PROTO_PAGE_FAULT == ERX_FIASCO_WIRE_PAGE_FAULT, "Fiasco's page fault protocol");
_Static_assert(L4_PROTO_EXCEPTION == ERX_FIASCO_WIRE_EXCEPTION, "Fiasco's exception protocol");
_Static_assert(L4_UTCB_EXCEPTION_REGS_SIZE == ERX_FIASCO_WIRE_EXCEPTION_WORDS, "Fiasco's exception length");

/*
 * Only the threads and semaphore race suites' images are built with this hook: the step of
 * a start to fail, 1 to 3 in the order they run, with 0 failing none.
 */
#ifdef ERX_FIASCO_TEST_HOOKS
_Atomic uint32_t erx_fiasco_test_start_fails;
#define SERVICE_START_FAILS(step) \
	(atomic_load_explicit(&erx_fiasco_test_start_fails, memory_order_relaxed) == (step))
#else
#define SERVICE_START_FAILS(step) false
#endif

extern char erx_fiasco_image_start[];
extern char erx_fiasco_image_end[];

static void	service_main(void);
static int	service_run(const erx_fiasco_wire_decoded_t *, erx_fiasco_reply_t *);
static bool	service_thread_name(uint32_t, uint64_t, uint32_t *, uint32_t *);
static int	service_thread_create(uint32_t, const erx_fiasco_thread_create_request_t *, erx_fiasco_reply_t *);
static int	service_thread_start(uint32_t, const erx_fiasco_thread_start_request_t *);
static bool	service_thread_steps(uint32_t, uint32_t, uint64_t);
static void	service_thread_delete(uint32_t, uint32_t);
static int	service_thread_reap(uint32_t, uint64_t);
static int	service_thread_set_affinity(uint32_t, uint64_t, uint64_t);
static l4_sched_param_t service_sched_param(uint64_t);
static uint64_t service_cpus_online(void);
static const char *service_thread_table_init(void);
static const char *service_start(void);
static bool	service_failed(l4_msgtag_t);
static void	service_fault(uint32_t, const erx_crash_fault_t *);
static void	service_page_fault(const l4_msg_regs_t *, uint32_t);
static void	service_exception(const l4_exc_regs_t *, uint32_t);

static _Alignas(16) uint8_t service_stack[SERVICE_STACK_BYTES];
/* Counted, never printed: a label naming no live task. */
static _Atomic uint64_t service_dropped;

/* The gate and the service thread sit past both per-thread runs of slots. */
uint64_t
erx_fiasco_service_gate(void)
{
	return (erx_fiasco_root_slot_cap(ERX_FIASCO_SLOT_SERVICE_GATE));
}

uint64_t
erx_fiasco_service_thread(void)
{
	return (erx_fiasco_root_slot_cap(ERX_FIASCO_SLOT_SERVICE_THREAD));
}

const char *
erx_fiasco_root_up(const void *archive, size_t archive_bytes)
{
	const char *reason;

	/*
	 * sigma0's RAM request maps read, write and execute whatever the page's
	 * sub-type says, which the archive's read-only pages must not get: it stays on
	 * the fault path, and the touch below is what maps it.
	 */
	if (l4sigma0_map_mem(L4_BASE_PAGER_CAP, (l4_addr_t)erx_fiasco_image_start,
	    (l4_addr_t)erx_fiasco_image_start,
	    (l4_addr_t)(erx_fiasco_image_end - erx_fiasco_image_start)) != 0)
		return ("image: sigma0 refused to map the root's own pages");
	for (size_t offset = 0; offset < archive_bytes; offset += ERX_PAGE_SIZE)
		(void)*(const volatile uint8_t *)((const char *)archive + offset);

	reason = erx_fiasco_vm_init();
	if (reason != NULL)
		return (reason);
	reason = service_thread_table_init();
	if (reason != NULL)
		return (reason);
	erx_fiasco_time_init();
	erx_fiasco_entropy_init();
	erx_fiasco_task_table_init();
	reason = service_start();
	if (reason != NULL)
		return (reason);
	return (erx_fiasco_reaper_start());
}

/* The root's thread table: its pages, its native UTCB slots, and the first thread's semaphore. */
static const char *
service_thread_table_init(void)
{
	const uint64_t table = (uint64_t)(uintptr_t)erx_fiasco_thread_record(0);
	l4_fpage_t area = l4_fpage(erx_fiasco_thread_native_slot(0), ERX_FIASCO_UTCB_AREA_ORDER, L4_FPAGE_RW);
	uint64_t reserved;

	if (erx_fiasco_vm_body(ERX_FIASCO_TASK_ROOT, ERX_BACKEND_VM_RESERVE, table, ERX_FIASCO_THREAD_TABLE_BYTES, ERX_VM_FIXED,
	    &reserved) != ERX_OK ||
	    erx_fiasco_vm_body(ERX_FIASCO_TASK_ROOT, ERX_BACKEND_VM_COMMIT, table, ERX_FIASCO_THREAD_TABLE_BYTES, 0, NULL) != ERX_OK)
		return ("threads: no memory for the thread table");
	if (l4_error(l4_task_add_ku_mem(L4_BASE_TASK_CAP, &area)) < 0)
		return ("threads: the kernel refused the UTCB area");
	if (l4_error(l4_factory_create(L4_BASE_FACTORY_CAP, L4_PROTO_SEMAPHORE,
	    erx_fiasco_thread_semaphore_cap(0))) < 0)
		return ("threads: the kernel refused the first thread's semaphore");
	erx_fiasco_thread_first_init();
	return (NULL);
}

static bool
service_failed(l4_msgtag_t tag)
{
	return (l4_error(tag) < 0);
}

/*
 * The service keeps sigma0 as its pager, so its own fault never reaches itself,
 * and takes the free slot of the kernel-given UTCB page: it holds no thread index.
 */
static const char *
service_start(void)
{
	const l4_sched_param_t param = l4_sched_param(SERVICE_THREAD_PRIORITY, 0);

	if (service_failed(l4_factory_create_thread(L4_BASE_FACTORY_CAP, erx_fiasco_service_thread())))
		return ("service: the kernel refused its thread");
	l4_thread_control_start();
	l4_thread_control_pager(L4_BASE_PAGER_CAP);
	l4_thread_control_exc_handler(L4_BASE_PAGER_CAP);
	l4_thread_control_bind((l4_utcb_t *)((char *)l4_utcb() + L4_UTCB_OFFSET), L4_BASE_TASK_CAP);
	if (service_failed(l4_thread_control_commit(erx_fiasco_service_thread())))
		return ("service: the kernel refused its thread's control");
	if (service_failed(l4_factory_create_gate(L4_BASE_FACTORY_CAP, erx_fiasco_service_gate(), erx_fiasco_service_thread(),
	    ERX_FIASCO_TASK_ROOT << ERX_FIASCO_WIRE_LABEL_SHIFT)))
		return ("service: the kernel refused the root's gate");

	l4_thread_control_start();
	l4_thread_control_pager(erx_fiasco_service_gate());
	l4_thread_control_exc_handler(erx_fiasco_service_gate());
	if (service_failed(l4_thread_control_commit(L4_BASE_THREAD_CAP)))
		return ("service: the kernel refused the root's new pager");

	if (service_failed(l4_thread_ex_regs(erx_fiasco_service_thread(), (l4_addr_t)service_main,
	    (l4_addr_t)(service_stack + sizeof(service_stack)), 0)))
		return ("service: the kernel refused its registers");
	if (service_failed(l4_scheduler_run_thread(L4_BASE_SCHEDULER_CAP, erx_fiasco_service_thread(), &param)))
		return ("service: the kernel would not run it");
	return (NULL);
}

static void
service_main(void)
{
	l4_utcb_t *const utcb = l4_utcb();
	l4_msg_regs_t *const mr = l4_utcb_mr_u(utcb);
	erx_fiasco_wire_decoded_t decoded;
	erx_fiasco_reply_t reply;
	l4_umword_t label;
	l4_msgtag_t tag;
	int status;

	tag = l4_ipc_wait(utcb, &label, L4_IPC_NEVER);
	for (;;) {
		/* A failed reply never reaches the receive: wait afresh. */
		if (l4_ipc_error(tag, utcb) != 0) {
			tag = l4_ipc_wait(utcb, &label, L4_IPC_NEVER);
			continue;
		}
		const erx_fiasco_wire_input_t input = { .label = label, .tag_label = l4_msgtag_label(tag),
		    .words = (uint32_t)l4_msgtag_words(tag), .live_mask = erx_fiasco_task_live_mask(),
		    .mr = (const uint64_t *)mr->mr };

		decoded = erx_fiasco_wire_decode(&input);
		switch (decoded.kind) {
		case ERX_FIASCO_WIRE_DROP:
			atomic_fetch_add_explicit(&service_dropped, 1, memory_order_relaxed);
			tag = l4_ipc_wait(utcb, &label, L4_IPC_NEVER);
			continue;
		case ERX_FIASCO_WIRE_FAULT_PAGE:
			service_page_fault(mr, decoded.task);
			tag = l4_ipc_wait(utcb, &label, L4_IPC_NEVER);
			continue;
		case ERX_FIASCO_WIRE_FAULT_EXCEPTION:
			service_exception(l4_utcb_exc_u(utcb), decoded.task);
			tag = l4_ipc_wait(utcb, &label, L4_IPC_NEVER);
			continue;
		case ERX_FIASCO_WIRE_REFUSE:
			reply = (erx_fiasco_reply_t){ .status = decoded.status };
			break;
		case ERX_FIASCO_WIRE_REQUEST:
			reply = (erx_fiasco_reply_t){ .status = 0 };
			status = service_run(&decoded, &reply);
			if (status == ERX_FIASCO_NO_REPLY) {
				tag = l4_ipc_wait(utcb, &label, L4_IPC_NEVER);
				continue;
			}
			reply.status = status;
			break;
		}
		mr->mr[0] = (l4_umword_t)reply.status;
		mr->mr[1] = reply.first;
		mr->mr[2] = reply.second;
		tag = l4_ipc_reply_and_wait(utcb, l4_msgtag(0, 3, 0, 0), &label, L4_IPC_SEND_TIMEOUT_0);
	}
}

/*
 * The IRQ calls. Their one table holds the root's objects, bound to the root's threads,
 * and no task has a consumer for them, so a task's call is refused rather than taking
 * a root thread of the same index for its own.
 */
static int
service_irq(const erx_fiasco_wire_decoded_t *decoded, erx_fiasco_reply_t *reply)
{
	const void *const words = decoded->request;

	if (decoded->task != ERX_FIASCO_TASK_ROOT)
		return (ERX_ENOTSUP);
	switch (decoded->call) {
	case ERX_FIASCO_CALL_IRQ_CREATE:
		return (erx_fiasco_irq_create_body(((const erx_fiasco_irq_create_request_t *)words)->kind,
		    ((const erx_fiasco_irq_create_request_t *)words)->selector, &reply->first));
	case ERX_FIASCO_CALL_IRQ_BIND:
		return (erx_fiasco_irq_bind_body(((const erx_fiasco_irq_bind_request_t *)words)->irq,
		    ((const erx_fiasco_irq_bind_request_t *)words)->thread,
		    ((const erx_fiasco_irq_bind_request_t *)words)->record));
	case ERX_FIASCO_CALL_IRQ_ACK:
		return (erx_fiasco_irq_ack_body(((const erx_fiasco_irq_request_t *)words)->irq));
	case ERX_FIASCO_CALL_IRQ_TRIGGER:
		return (erx_fiasco_irq_trigger_body(((const erx_fiasco_irq_request_t *)words)->irq));
	default:
		return (ERX_ENOTSUP);
	}
}

static int
service_run(const erx_fiasco_wire_decoded_t *decoded, erx_fiasco_reply_t *reply)
{
	const void *const words = decoded->request;
	const erx_fiasco_vm_range_request_t *const range = words;
	const erx_fiasco_vm_flagged_request_t *const flagged = words;

	switch (decoded->call) {
	case ERX_FIASCO_CALL_THREAD_CREATE:
		return (service_thread_create(decoded->task, words, reply));
	case ERX_FIASCO_CALL_THREAD_START:
		return (service_thread_start(decoded->task, words));
	case ERX_FIASCO_CALL_THREAD_SET_AFFINITY:
		return (service_thread_set_affinity(decoded->task, ((const erx_fiasco_thread_set_affinity_request_t *)words)->thread,
		    ((const erx_fiasco_thread_set_affinity_request_t *)words)->mask));
	case ERX_FIASCO_CALL_THREAD_REAP:
		return (service_thread_reap(decoded->task, ((const erx_fiasco_thread_reap_request_t *)words)->thread));
	case ERX_FIASCO_CALL_VM_RESERVE:
		if (flagged->flags > UINT32_MAX)
			return (ERX_EINVAL);
		return (erx_fiasco_vm_body(decoded->task, ERX_BACKEND_VM_RESERVE, flagged->addr, flagged->size,
		    (uint32_t)flagged->flags, &reply->first));
	case ERX_FIASCO_CALL_VM_COMMIT:
		return (erx_fiasco_vm_body(decoded->task, ERX_BACKEND_VM_COMMIT, range->addr, range->size, 0, NULL));
	case ERX_FIASCO_CALL_VM_DECOMMIT:
		return (erx_fiasco_vm_body(decoded->task, ERX_BACKEND_VM_DECOMMIT, range->addr, range->size, 0, NULL));
	case ERX_FIASCO_CALL_VM_RELEASE:
		return (erx_fiasco_vm_body(decoded->task, ERX_BACKEND_VM_RELEASE, range->addr, range->size, 0, NULL));
	case ERX_FIASCO_CALL_SPACE_PROTECT:
		if (flagged->flags > UINT32_MAX)
			return (ERX_EINVAL);
		return (erx_fiasco_vm_body(decoded->task, ERX_BACKEND_VM_PROTECT, flagged->addr, flagged->size,
		    (uint32_t)flagged->flags, NULL));
	case ERX_FIASCO_CALL_IRQ_CREATE:
	case ERX_FIASCO_CALL_IRQ_BIND:
	case ERX_FIASCO_CALL_IRQ_ACK:
	case ERX_FIASCO_CALL_IRQ_TRIGGER:
		return (service_irq(decoded, reply));
	case ERX_FIASCO_CALL_TIME_SET_WALL:
		return (erx_fiasco_time_set_wall_body(((const erx_fiasco_time_set_wall_request_t *)words)->wall_ns));
	case ERX_FIASCO_CALL_MEM_CREATE:
		return (erx_fiasco_task_mem_create_body(decoded->task, ((const erx_fiasco_mem_create_request_t *)words)->size,
		    ((const erx_fiasco_mem_create_request_t *)words)->flags, &reply->first));
	case ERX_FIASCO_CALL_MEM_CREATE_PHYSICAL:
		return (erx_fiasco_task_mem_physical_body(decoded->task, words, &reply->first));
	case ERX_FIASCO_CALL_MEM_CREATE_CONTIGUOUS:
		return (erx_fiasco_task_mem_contiguous_body(decoded->task, words, &reply->first));
	case ERX_FIASCO_CALL_MEM_DMA_ADDR:
		return (erx_fiasco_vm_object_dma_addr(decoded->task, ((const erx_fiasco_mem_dma_request_t *)words)->mem,
		    ((const erx_fiasco_mem_dma_request_t *)words)->offset, &reply->first));
	case ERX_FIASCO_CALL_ENTROPY_READ:
		return (erx_fiasco_entropy_read_body(&reply->first, &reply->second));
	case ERX_FIASCO_CALL_ENTROPY_ADD:
		return (erx_fiasco_entropy_add_body(words));
	case ERX_FIASCO_CALL_VM_MAP:
		return (erx_fiasco_task_vm_map_body(decoded->task, words));
	case ERX_FIASCO_CALL_SPACE_CREATE:
		return (erx_fiasco_task_create_body(decoded->task, ((const erx_fiasco_space_create_request_t *)words)->flags,
		    &reply->first));
	case ERX_FIASCO_CALL_IMAGE_MAP:
		return (erx_fiasco_task_image_map_body(decoded->task, ((const erx_fiasco_image_map_request_t *)words)->space,
		    ((const erx_fiasco_image_map_request_t *)words)->entry, &reply->first));
	case ERX_FIASCO_CALL_SPACE_STOP:
		return (erx_fiasco_task_stop_body(decoded->task, ((const erx_fiasco_space_stop_request_t *)words)->space,
		    ((const erx_fiasco_space_stop_request_t *)words)->status));
	case ERX_FIASCO_CALL_TASK_JOIN:
		return (erx_fiasco_task_join_body(decoded->task, ((const erx_fiasco_task_join_request_t *)words)->task,
		    (int64_t *)(void *)&reply->first));
	case ERX_FIASCO_CALL_MACHINE_END: {
		const uint64_t how = ((const erx_fiasco_machine_end_request_t *)words)->how;

		if (how != ERX_END_OFF && how != ERX_END_RESET)
			return (ERX_EINVAL);
		erx_fiasco_end(NULL, (uint32_t)how);
	}
	default:
		return (ERX_ENOTSUP);
	}
}

/*
 * A thread handle, for the calling task: a task's own handle is an index, and the
 * root's handle of another task's thread carries that task above the index. These
 * two are the service's directions; the stubs in thread.c and irq.c read a task's
 * own handle as its index.
 */
static uint64_t
service_thread_handle(uint32_t caller, uint32_t task, uint32_t index)
{
	return (task == caller ? index : (uint64_t)task << SERVICE_HANDLE_TASK_SHIFT | index);
}

static bool
service_thread_name(uint32_t caller, uint64_t handle, uint32_t *task, uint32_t *index)
{
	const uint64_t named = handle >> SERVICE_HANDLE_TASK_SHIFT;

	if ((named != 0 && caller != ERX_FIASCO_TASK_ROOT) || named >= ERX_FIASCO_TASKS_MAX ||
	    (handle & SERVICE_HANDLE_INDEX_MASK) >= ERX_FIASCO_THREADS_MAX)
		return (false);
	*task = named != 0 ? (uint32_t)named : caller;
	*index = (uint32_t)(handle & SERVICE_HANDLE_INDEX_MASK);
	return (erx_fiasco_task(*task)->state == ERX_FIASCO_TASK_LIVE);
}

/*
 * Makes the kernel's objects for an index the stub claimed, or for the first thread
 * of a task the root names, and takes the starting registers from the caller's
 * public UTCB. Everything goes through the window, so the record may be another task's.
 * A task holds its semaphore at the same slot the root's own threads use.
 */
static int
service_thread_create(uint32_t caller, const erx_fiasco_thread_create_request_t *request, erx_fiasco_reply_t *reply)
{
	erx_fiasco_thread_record_t *record;
	const erx_fiasco_thread_record_t *from;
	erx_fiasco_task_t *row;
	uint64_t *start;
	uint32_t index, task = caller;

	if (request->space != 0) {
		if (caller != ERX_FIASCO_TASK_ROOT || !erx_fiasco_task_space_decode(request->space, &task) || request->index != 0)
			return (ERX_EINVAL);
	}
	row = erx_fiasco_task(task);
	if (request->index >= ERX_FIASCO_THREADS_MAX || row->state != ERX_FIASCO_TASK_LIVE ||
	    row->threads[request->index] != ERX_FIASCO_TASK_THREAD_ABSENT)
		return (ERX_EINVAL);
	index = (uint32_t)request->index;
	record = erx_fiasco_task_record(task, index);
	from = erx_fiasco_task_record(caller, (uint32_t)request->caller);
	if (record == NULL || from == NULL)
		return (ERX_EINVAL);
	if (service_failed(l4_factory_create_thread(L4_BASE_FACTORY_CAP, erx_fiasco_task_thread_cap(task, index))))
		return (ERX_ENOMEM);
	if (service_failed(l4_factory_create(L4_BASE_FACTORY_CAP, L4_PROTO_SEMAPHORE,
	    erx_fiasco_task_semaphore_cap(task, index))) ||
	    (task != ERX_FIASCO_TASK_ROOT && service_failed(l4_task_map(erx_fiasco_task_cap(task), L4_BASE_TASK_CAP,
	    l4_obj_fpage(erx_fiasco_task_semaphore_cap(task, index), 0, L4_CAP_FPAGE_RWS),
	    l4_map_obj_control(erx_fiasco_thread_semaphore_cap(index), L4_MAP_ITEM_MAP))))) {
		service_thread_delete(task, index);
		return (ERX_ENOMEM);
	}

	start = (uint64_t *)(void *)&record->start;
	for (size_t word = 0; word < sizeof(record->start) / sizeof(uint64_t); word++)
		start[word] = atomic_load_explicit(&from->utcb.mr[word], memory_order_relaxed);
	row->threads[index] = ERX_FIASCO_TASK_THREAD_CREATED;
	reply->first = service_thread_handle(caller, task, index);
	reply->second = erx_fiasco_thread_semaphore_cap(index);
	return (ERX_OK);
}

/*
 * If a step fails the thread and semaphore go first, and only then the reply: the
 * thread was never runnable, or the deletion's return means it never reaches user
 * mode again, so the caller may free its stack. A thread starts at its own task's
 * trampoline, whose address its stub sends; a task's first thread starts at the
 * image's entry, the only address of the task the root knows.
 */
static int
service_thread_start(uint32_t caller, const erx_fiasco_thread_start_request_t *request)
{
	uint32_t index, task;
	uint64_t ip;

	if (!service_thread_name(caller, request->thread, &task, &index) ||
	    erx_fiasco_task(task)->threads[index] != ERX_FIASCO_TASK_THREAD_CREATED || (task != caller && index != 0))
		return (ERX_EINVAL);
	ip = task == caller ? request->trampoline : erx_fiasco_task(task)->entry;

	if (!service_thread_steps(task, index, ip)) {
		service_thread_delete(task, index);
		return (ERX_ENOMEM);
	}
	erx_fiasco_task(task)->threads[index] = ERX_FIASCO_TASK_THREAD_STARTED;
	return (ERX_OK);
}

/* The three steps of a start, in order. The first refusal stops them. */
static bool
service_thread_steps(uint32_t task, uint32_t index, uint64_t ip)
{
	const l4_cap_idx_t cap = erx_fiasco_task_thread_cap(task, index);
	const l4_sched_param_t param = service_sched_param(erx_fiasco_task(task)->affinity[index]);

	l4_thread_control_start();
	l4_thread_control_pager(erx_fiasco_task_gate_slot(task));
	l4_thread_control_exc_handler(erx_fiasco_task_gate_slot(task));
	l4_thread_control_bind((l4_utcb_t *)(uintptr_t)erx_fiasco_thread_native_slot(index), erx_fiasco_task_cap(task));
	if (SERVICE_START_FAILS(1) || service_failed(l4_thread_control_commit(cap)))
		return (false);
	if (SERVICE_START_FAILS(2) || service_failed(l4_thread_ex_regs(cap, (l4_addr_t)ip,
	    (l4_addr_t)(uintptr_t)erx_fiasco_thread_record(index), 0)))
		return (false);
	if (SERVICE_START_FAILS(3) || service_failed(l4_scheduler_run_thread(L4_BASE_SCHEDULER_CAP, cap, &param)))
		return (false);
	return (true);
}

/* A mask of 0 leaves the kernel's own: a thread stays on the CPU it was created on. */
static l4_sched_param_t
service_sched_param(uint64_t mask)
{
	l4_sched_param_t param = l4_sched_param(SERVICE_THREAD_PRIORITY, 0);

	if (mask != 0)
		param.affinity = l4_sched_cpu_set(0, 0, mask);
	return (param);
}

static uint64_t
service_cpus_online(void)
{
	l4_umword_t cpu_max;
	l4_sched_cpu_set_t cpus = l4_sched_cpu_set(0, 0, 0);

	if (service_failed(l4_scheduler_info(L4_BASE_SCHEDULER_CAP, &cpu_max, &cpus)))
		return (0);
	return (cpus.map);
}

/*
 * A thread not started yet takes the mask at its start, and a running one moves
 * now. Fiasco runs it on one CPU of the mask, its own if the mask holds it: a recorded
 * difference.
 */
static int
service_thread_set_affinity(uint32_t caller, uint64_t thread, uint64_t mask)
{
	erx_fiasco_task_t *row;
	l4_sched_param_t param;
	uint32_t index, task;

	if (!service_thread_name(caller, thread, &task, &index) || (mask & service_cpus_online()) == 0)
		return (ERX_EINVAL);
	row = erx_fiasco_task(task);
	if (row->threads[index] == ERX_FIASCO_TASK_THREAD_ABSENT)
		return (ERX_EINVAL);
	row->affinity[index] = mask;
	if (row->threads[index] != ERX_FIASCO_TASK_THREAD_STARTED)
		return (ERX_OK);
	param = service_sched_param(mask);
	if (service_failed(l4_scheduler_run_thread(L4_BASE_SCHEDULER_CAP, erx_fiasco_task_thread_cap(task, index), &param)))
		return (ERX_EINVAL);
	return (ERX_OK);
}

/* The reaper's request: the thread has exited, and asked for this by its record. */
static int
service_thread_reap(uint32_t caller, uint64_t thread)
{
	if (thread >= ERX_FIASCO_THREADS_MAX ||
	    erx_fiasco_task(caller)->threads[thread] != ERX_FIASCO_TASK_THREAD_STARTED)
		return (ERX_EINVAL);
	service_thread_delete(caller, (uint32_t)thread);
	return (ERX_OK);
}

/* A deletion the root cannot perform leaves a thread it cannot account for: the machine ends. */
static void
service_thread_delete(uint32_t task, uint32_t index)
{
	static const char line[] = "erx: service: the kernel refused a deletion\n";
	erx_fiasco_task_t *const row = erx_fiasco_task(task);

	row->threads[index] = ERX_FIASCO_TASK_THREAD_ABSENT;
	row->affinity[index] = 0;
	if (service_failed(l4_task_delete_obj(L4_BASE_TASK_CAP, erx_fiasco_task_thread_cap(task, index))) ||
	    service_failed(l4_task_delete_obj(L4_BASE_TASK_CAP, erx_fiasco_task_semaphore_cap(task, index)))) {
		erx_fiasco_console_write(line, sizeof(line) - 1);
		erx_fiasco_machine_off();
	}
}

#ifdef ERX_FIASCO_TEST_HOOKS
bool
erx_fiasco_test_thread_caps_gone(uint32_t index)
{
	return (l4_msgtag_label(l4_task_cap_valid(L4_BASE_TASK_CAP, erx_fiasco_task_thread_cap(ERX_FIASCO_TASK_ROOT, index))) == 0 &&
	    l4_msgtag_label(l4_task_cap_valid(L4_BASE_TASK_CAP, erx_fiasco_thread_semaphore_cap(index))) == 0);
}

uint64_t
erx_fiasco_test_dropped(void)
{
	return (atomic_load_explicit(&service_dropped, memory_order_relaxed));
}

uint32_t
erx_fiasco_test_cpu_count(void)
{
	return ((uint32_t)__builtin_popcountll(service_cpus_online()));
}

/* Raises a thread above its CPU's others, which is how the suite sees where it runs. */
int
erx_fiasco_test_thread_priority(uint32_t index, uint32_t priority, uint64_t mask)
{
	l4_sched_param_t param = l4_sched_param(priority, 0);

	param.affinity = l4_sched_cpu_set(0, 0, mask);
	return (service_failed(l4_scheduler_run_thread(L4_BASE_SCHEDULER_CAP, erx_fiasco_thread_cap(index), &param)) ?
	    ERX_EINVAL : ERX_OK);
}
#endif

/* The root's fault ends the machine; a task's ends only the task. */
static void
service_fault(uint32_t task, const erx_crash_fault_t *fault)
{
	if (task == ERX_FIASCO_TASK_ROOT)
		erx_fiasco_end(fault, ERX_END_OFF);
	erx_fiasco_task_fault(task, fault);
}

static void
service_page_fault(const l4_msg_regs_t *mr, uint32_t task)
{
	const erx_crash_fault_t fault = { .kind = ERX_FAULT_MEMORY,
	    .cause = (uint32_t)(mr->mr[0] & SERVICE_FAULT_ACCESS), .addr = mr->mr[0] & ~SERVICE_FAULT_ACCESS,
	    .pc = mr->mr[1], .thread = SERVICE_THREAD_UNKNOWN, .space = task };

	service_fault(task, &fault);
}

static void
service_exception(const l4_exc_regs_t *regs, uint32_t task)
{
	const erx_crash_fault_t fault = { .kind = ERX_FAULT_UNDEFINED, .cause = (uint32_t)regs->err,
	    .addr = regs->pfa, .pc = regs->pc, .thread = SERVICE_THREAD_UNKNOWN, .space = task };

	service_fault(task, &fault);
}
