/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

/*
 * The root service's thread: the root's first steps up to it, its loop, and the
 * calls' bodies. It runs each body to its end before the next receive, so what
 * only it touches needs no lock, and a body never sends a request. A fault is one
 * more message, never answered: every committed page is already mapped, so the
 * fault of a root thread ends the machine. The service's own fault goes to sigma0,
 * which repairs nothing: a recorded gap.
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
#include "liberx/backend/fiasco/service.h"
#include "liberx/backend/fiasco/service_wire.h"
#include "liberx/backend/fiasco/thread.h"
#include "liberx/backend/fiasco/vm.h"

#define SERVICE_STACK_BYTES	16384u
/* The default priority of every thread but the watchdog. */
#define SERVICE_THREAD_PRIORITY	1u
/* Only the root exists; a task's index is its gate's label. */
#define SERVICE_ROOT_TASK	0u
#define SERVICE_LIVE_TASKS	1u
/* A thread the fault cannot name. */
#define SERVICE_THREAD_UNKNOWN	UINT64_MAX
/* The fault word's low bits say how the page was touched. */
#define SERVICE_FAULT_ACCESS	UINT64_C(7)

_Static_assert(L4_PROTO_PAGE_FAULT == ERX_FIASCO_WIRE_PAGE_FAULT, "Fiasco's page fault protocol");
_Static_assert(L4_PROTO_EXCEPTION == ERX_FIASCO_WIRE_EXCEPTION, "Fiasco's exception protocol");
_Static_assert(sizeof(l4_exc_regs_t) <= ERX_FIASCO_WIRE_EXCEPTION_WORDS * sizeof(uint64_t), "the exception's words hold its registers");

/*
 * The threads suite's image is built with this hook, and no other is: the step of
 * a start to fail, 1 to 3 in the order they run, with 0 failing none.
 */
#ifdef ERX_FIASCO_TEST_HOOKS
_Atomic uint32_t erx_fiasco_test_start_fails;
#define SERVICE_START_FAILS(step) \
	(atomic_load_explicit(&erx_fiasco_test_start_fails, memory_order_relaxed) == (step))
#else
#define SERVICE_START_FAILS(step) false
#endif

typedef enum service_thread_state {
	SERVICE_THREAD_ABSENT = 0,
	SERVICE_THREAD_CREATED,
	SERVICE_THREAD_STARTED
} service_thread_state_t;

extern char erx_fiasco_image_start[];
extern char erx_fiasco_image_end[];

static void	service_main(void);
static int	service_run(const erx_fiasco_wire_decoded_t *, erx_fiasco_reply_t *);
static int	service_thread_create(const erx_fiasco_thread_create_request_t *, erx_fiasco_reply_t *);
static int	service_thread_start(uint64_t);
static bool	service_thread_steps(uint32_t, l4_cap_idx_t);
static void	service_thread_delete(uint32_t);
static int	service_thread_reap(uint64_t);
static int	service_thread_set_affinity(uint64_t, uint64_t);
static l4_sched_param_t service_sched_param(uint64_t);
static uint64_t service_cpus_online(void);
static l4_cap_idx_t service_thread_cap(uint32_t);
static const char *service_start(void);
static bool	service_failed(l4_msgtag_t);
static _Noreturn void service_page_fault(const l4_msg_regs_t *, uint32_t);
static _Noreturn void service_exception(const l4_exc_regs_t *, uint32_t);

static _Alignas(16) uint8_t service_stack[SERVICE_STACK_BYTES];
/* Which indices hold a live thread; only the service writes it once running. */
static service_thread_state_t service_threads[ERX_FIASCO_THREADS_MAX];
/* Each thread's CPUs as last set, 0 for wherever it was created. */
static uint64_t service_affinity[ERX_FIASCO_THREADS_MAX];
/* Counted, never printed: a label naming no live task. */
static _Atomic uint64_t service_dropped;

/* The gate and the service thread sit past both per-thread runs of slots. */
uint64_t
erx_fiasco_service_gate(void)
{
	return (erx_fiasco_thread_cap(ERX_FIASCO_THREADS_MAX));
}

static l4_cap_idx_t
service_thread(void)
{
	return ((l4_cap_idx_t)erx_fiasco_thread_cap(ERX_FIASCO_THREADS_MAX + 1));
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
	reason = erx_fiasco_thread_table_init();
	if (reason != NULL)
		return (reason);
	service_threads[0] = SERVICE_THREAD_STARTED;
	reason = service_start();
	if (reason != NULL)
		return (reason);
	return (erx_fiasco_reaper_start());
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

	if (service_failed(l4_factory_create_thread(L4_BASE_FACTORY_CAP, service_thread())))
		return ("service: the kernel refused its thread");
	l4_thread_control_start();
	l4_thread_control_pager(L4_BASE_PAGER_CAP);
	l4_thread_control_exc_handler(L4_BASE_PAGER_CAP);
	l4_thread_control_bind((l4_utcb_t *)((char *)l4_utcb() + L4_UTCB_OFFSET), L4_BASE_TASK_CAP);
	if (service_failed(l4_thread_control_commit(service_thread())))
		return ("service: the kernel refused its thread's control");
	if (service_failed(l4_factory_create_gate(L4_BASE_FACTORY_CAP, erx_fiasco_service_gate(), service_thread(),
	    SERVICE_ROOT_TASK << ERX_FIASCO_WIRE_LABEL_SHIFT)))
		return ("service: the kernel refused the root's gate");

	l4_thread_control_start();
	l4_thread_control_pager(erx_fiasco_service_gate());
	l4_thread_control_exc_handler(erx_fiasco_service_gate());
	if (service_failed(l4_thread_control_commit(L4_BASE_THREAD_CAP)))
		return ("service: the kernel refused the root's new pager");

	if (service_failed(l4_thread_ex_regs(service_thread(), (l4_addr_t)service_main,
	    (l4_addr_t)(service_stack + sizeof(service_stack)), 0)))
		return ("service: the kernel refused its registers");
	if (service_failed(l4_scheduler_run_thread(L4_BASE_SCHEDULER_CAP, service_thread(), &param)))
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
		    .words = (uint32_t)l4_msgtag_words(tag), .live_tasks = SERVICE_LIVE_TASKS,
		    .mr = (const uint64_t *)mr->mr };

		decoded = erx_fiasco_wire_decode(&input);
		switch (decoded.kind) {
		case ERX_FIASCO_WIRE_DROP:
			atomic_fetch_add_explicit(&service_dropped, 1, memory_order_relaxed);
			tag = l4_ipc_wait(utcb, &label, L4_IPC_NEVER);
			continue;
		case ERX_FIASCO_WIRE_FAULT_PAGE:
			service_page_fault(mr, decoded.task);
		case ERX_FIASCO_WIRE_FAULT_EXCEPTION:
			service_exception(l4_utcb_exc_u(utcb), decoded.task);
		case ERX_FIASCO_WIRE_REFUSE:
			reply = (erx_fiasco_reply_t){ .status = decoded.status };
			break;
		case ERX_FIASCO_WIRE_REQUEST:
			reply = (erx_fiasco_reply_t){ .status = 0 };
			status = service_run(&decoded, &reply);
			reply.status = status;
			break;
		}
		mr->mr[0] = (l4_umword_t)reply.status;
		mr->mr[1] = reply.first;
		mr->mr[2] = reply.second;
		tag = l4_ipc_reply_and_wait(utcb, l4_msgtag(0, 3, 0, 0), &label, L4_IPC_SEND_TIMEOUT_0);
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
		return (service_thread_create(words, reply));
	case ERX_FIASCO_CALL_THREAD_START:
		return (service_thread_start(((const erx_fiasco_thread_start_request_t *)words)->thread));
	case ERX_FIASCO_CALL_THREAD_SET_AFFINITY:
		return (service_thread_set_affinity(((const erx_fiasco_thread_set_affinity_request_t *)words)->thread,
		    ((const erx_fiasco_thread_set_affinity_request_t *)words)->mask));
	case ERX_FIASCO_CALL_THREAD_REAP:
		return (service_thread_reap(((const erx_fiasco_thread_reap_request_t *)words)->thread));
	case ERX_FIASCO_CALL_VM_RESERVE:
		if (flagged->flags > UINT32_MAX)
			return (ERX_EINVAL);
		return (erx_fiasco_vm_body(ERX_FIASCO_VM_RESERVE, flagged->addr, flagged->size,
		    (uint32_t)flagged->flags, &reply->first));
	case ERX_FIASCO_CALL_VM_COMMIT:
		return (erx_fiasco_vm_body(ERX_FIASCO_VM_COMMIT, range->addr, range->size, 0, NULL));
	case ERX_FIASCO_CALL_VM_DECOMMIT:
		return (erx_fiasco_vm_body(ERX_FIASCO_VM_DECOMMIT, range->addr, range->size, 0, NULL));
	case ERX_FIASCO_CALL_VM_RELEASE:
		return (erx_fiasco_vm_body(ERX_FIASCO_VM_RELEASE, range->addr, range->size, 0, NULL));
	case ERX_FIASCO_CALL_SPACE_PROTECT:
		if (flagged->flags > UINT32_MAX)
			return (ERX_EINVAL);
		return (erx_fiasco_vm_body(ERX_FIASCO_VM_PROTECT, flagged->addr, flagged->size,
		    (uint32_t)flagged->flags, NULL));
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
 * Makes the kernel's objects for an index the stub claimed, and takes the starting
 * registers from the caller's public UTCB. The caller's own task is the only space.
 */
static int
service_thread_create(const erx_fiasco_thread_create_request_t *request, erx_fiasco_reply_t *reply)
{
	erx_fiasco_thread_record_t *record;
	const erx_fiasco_thread_record_t *caller;
	uint64_t *start;
	uint32_t index;

	if (request->index >= ERX_FIASCO_THREADS_MAX || request->space != 0 ||
	    service_threads[request->index] != SERVICE_THREAD_ABSENT)
		return (ERX_EINVAL);
	index = (uint32_t)request->index;
	if (service_failed(l4_factory_create_thread(L4_BASE_FACTORY_CAP, erx_fiasco_thread_cap(index))))
		return (ERX_ENOMEM);
	if (service_failed(l4_factory_create(L4_BASE_FACTORY_CAP, L4_PROTO_SEMAPHORE,
	    erx_fiasco_thread_semaphore_cap(index)))) {
		service_thread_delete(index);
		return (ERX_ENOMEM);
	}

	record = erx_fiasco_thread_record(index);
	caller = erx_fiasco_thread_record((uint32_t)request->caller);
	start = (uint64_t *)(void *)&record->start;
	for (size_t word = 0; word < sizeof(record->start) / sizeof(uint64_t); word++)
		start[word] = atomic_load_explicit(&caller->utcb.mr[word], memory_order_relaxed);
	service_threads[index] = SERVICE_THREAD_CREATED;
	reply->first = index;
	reply->second = erx_fiasco_thread_semaphore_cap(index);
	return (ERX_OK);
}

/*
 * If a step fails the thread and semaphore go first, and only then the reply: the
 * thread was never runnable, or the deletion's return means it never reaches user
 * mode again, so the caller may free its stack.
 */
static int
service_thread_start(uint64_t thread)
{
	l4_cap_idx_t cap;
	uint32_t index;

	if (thread >= ERX_FIASCO_THREADS_MAX || service_threads[thread] != SERVICE_THREAD_CREATED)
		return (ERX_EINVAL);
	index = (uint32_t)thread;
	cap = erx_fiasco_thread_cap(index);

	if (!service_thread_steps(index, cap)) {
		service_thread_delete(index);
		return (ERX_ENOMEM);
	}
	service_threads[index] = SERVICE_THREAD_STARTED;
	return (ERX_OK);
}

/* The three steps of a start, in order. The first refusal stops them. */
static bool
service_thread_steps(uint32_t index, l4_cap_idx_t cap)
{
	const l4_sched_param_t param = service_sched_param(service_affinity[index]);

	l4_thread_control_start();
	l4_thread_control_pager(erx_fiasco_service_gate());
	l4_thread_control_exc_handler(erx_fiasco_service_gate());
	l4_thread_control_bind((l4_utcb_t *)(uintptr_t)erx_fiasco_thread_native_slot(index), L4_BASE_TASK_CAP);
	if (SERVICE_START_FAILS(1) || service_failed(l4_thread_control_commit(cap)))
		return (false);
	if (SERVICE_START_FAILS(2) || service_failed(l4_thread_ex_regs(cap, (l4_addr_t)erx_fiasco_thread_trampoline,
	    (l4_addr_t)(uintptr_t)erx_fiasco_thread_record(index), 0)))
		return (false);
	if (SERVICE_START_FAILS(3) || service_failed(l4_scheduler_run_thread(L4_BASE_SCHEDULER_CAP, cap, &param)))
		return (false);
	return (true);
}

/* The first thread's capability is the one the kernel gave it. */
static l4_cap_idx_t
service_thread_cap(uint32_t index)
{
	return (index == 0 ? L4_BASE_THREAD_CAP : (l4_cap_idx_t)erx_fiasco_thread_cap(index));
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
service_thread_set_affinity(uint64_t thread, uint64_t mask)
{
	l4_sched_param_t param;

	if (thread >= ERX_FIASCO_THREADS_MAX || service_threads[thread] == SERVICE_THREAD_ABSENT ||
	    (mask & service_cpus_online()) == 0)
		return (ERX_EINVAL);
	service_affinity[thread] = mask;
	if (service_threads[thread] != SERVICE_THREAD_STARTED)
		return (ERX_OK);
	param = service_sched_param(mask);
	if (service_failed(l4_scheduler_run_thread(L4_BASE_SCHEDULER_CAP, service_thread_cap((uint32_t)thread), &param)))
		return (ERX_EINVAL);
	return (ERX_OK);
}

/* The reaper's request: the thread has exited, and asked for this by its record. */
static int
service_thread_reap(uint64_t thread)
{
	if (thread >= ERX_FIASCO_THREADS_MAX || service_threads[thread] != SERVICE_THREAD_STARTED)
		return (ERX_EINVAL);
	service_thread_delete((uint32_t)thread);
	return (ERX_OK);
}

/* A deletion the root cannot perform leaves a thread it cannot account for: the machine ends. */
static void
service_thread_delete(uint32_t index)
{
	static const char line[] = "erx: service: the kernel refused a deletion\n";

	service_threads[index] = SERVICE_THREAD_ABSENT;
	service_affinity[index] = 0;
	if (service_failed(l4_task_delete_obj(L4_BASE_TASK_CAP, service_thread_cap(index))) ||
	    service_failed(l4_task_delete_obj(L4_BASE_TASK_CAP, erx_fiasco_thread_semaphore_cap(index)))) {
		erx_fiasco_console_write(line, sizeof(line) - 1);
		erx_fiasco_machine_off();
	}
}

#ifdef ERX_FIASCO_TEST_HOOKS
bool
erx_fiasco_test_thread_caps_gone(uint32_t index)
{
	return (l4_msgtag_label(l4_task_cap_valid(L4_BASE_TASK_CAP, service_thread_cap(index))) == 0 &&
	    l4_msgtag_label(l4_task_cap_valid(L4_BASE_TASK_CAP, erx_fiasco_thread_semaphore_cap(index))) == 0);
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

static _Noreturn void
service_page_fault(const l4_msg_regs_t *mr, uint32_t task)
{
	const erx_crash_fault_t fault = { .kind = ERX_FAULT_MEMORY,
	    .cause = (uint32_t)(mr->mr[0] & SERVICE_FAULT_ACCESS), .addr = mr->mr[0] & ~SERVICE_FAULT_ACCESS,
	    .pc = mr->mr[1], .thread = SERVICE_THREAD_UNKNOWN, .space = task };

	erx_fiasco_end(&fault, ERX_END_OFF);
}

static _Noreturn void
service_exception(const l4_exc_regs_t *regs, uint32_t task)
{
	const erx_crash_fault_t fault = { .kind = ERX_FAULT_UNDEFINED, .cause = (uint32_t)regs->err,
	    .addr = regs->pfa, .pc = regs->pc, .thread = SERVICE_THREAD_UNKNOWN, .space = task };

	erx_fiasco_end(&fault, ERX_END_OFF);
}
