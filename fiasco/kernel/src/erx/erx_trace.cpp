// Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
// SPDX-License-Identifier: BSD-2-Clause
//
// The kernel's trace rings' one writer (docs/design-fiasco.md, "The kernel's
// trace rings"). A hook calls its event's function here (ipc_receive,
// switch_to). That function names its objects and calls Erx_trace::record,
// which fills an entry under the CPU lock and hands it to the C17 core's
// erx_trace_kernel_put for the current CPU's ring. The hooks' files see no core header: the event
// numbers stay in this file. The rings themselves are
// C (kernel/core/trace_rings.c) and reach this file only through the seam,
// erx/core/trace_kernel.h.
INTERFACE:

#include "types.h"

class Context;

class Erx_trace
{
};

IMPLEMENTATION:

#include "erx/core/clock_ns.h"
#include "erx/core/trace_kernel.h"
#include "config.h"
#include "context.h"
#include "cpu_lock.h"
#include "generic_timer.h"
#include "globals.h"
#include "lock_guard.h"
#include "task.h"
#include "thread.h"

// A CPU number the glue passes always names a ring.
static_assert(Config::Max_num_cpus <= ERX_TRACE_KERNEL_RINGS,
              "the kernel has more CPUs than trace rings");

// A thread's name in a record: Fiasco's object id plus one, so 0 stays
// "none". Every Context is a Thread.
static Unsigned64
trace_thread_id(Context const *ctx)
{
  return ctx ? Unsigned64{nonull_static_cast<Thread const *>(ctx)->dbg_info()->dbg_id()} + 1 : 0;
}

// The space a thread runs in, named the same way; every Space is a Task's.
static Unsigned64
trace_space_id(Context const *ctx)
{
  Space *space = ctx ? ctx->space() : nullptr;
  return space ? Unsigned64{static_cast<Task *>(space)->dbg_info()->dbg_id()} + 1 : 0;
}

// Writes one record of event on the current CPU's ring, with the thread the
// CPU runs and its space. The arguments are values the kernel holds, never
// addresses it stores through.
PRIVATE static
void
Erx_trace::record(Unsigned32 event, Unsigned64 arg0, Unsigned64 arg1,
                  Unsigned64 arg2)
{
  auto guard = lock_guard(cpu_lock);
  Context const *running = current();
  erx_trace_entry_t entry{};

  entry.time_ns = erx_clock_ticks_ns(Generic_timer::Gtimer::counter(),
                                     Generic_timer::Gtimer::frequency());
  entry.event = event;
  entry.thread = trace_thread_id(running);
  entry.space = trace_space_id(running);
  entry.arg[0] = arg0;
  entry.arg[1] = arg1;
  entry.arg[2] = arg2;
  erx_trace_kernel_put(cxx::int_value<Cpu_number>(current_cpu()), &entry);
}

// A message copied into receiver (Thread::transfer_msg), with tag as the
// receiver is given it.
PUBLIC static
void
Erx_trace::ipc_receive(Context const *sender, Context const *receiver,
                       Mword tag)
{
  record(ERX_TRACE_EVENT_IPC_RECEIVE, trace_thread_id(sender),
         trace_thread_id(receiver), tag);
}

// The CPU switches to next (Context::_switch_exec_common).
PUBLIC static
void
Erx_trace::switch_to(Context const *next)
{
  record(ERX_TRACE_EVENT_SWITCH, trace_thread_id(next), trace_space_id(next), 0);
}
