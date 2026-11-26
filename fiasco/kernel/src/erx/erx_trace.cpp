// Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
// SPDX-License-Identifier: BSD-2-Clause
//
// The kernel's trace rings' one writer (docs/design-fiasco.md, "The kernel's
// trace rings"). A hook calls its event's function here (ipc_receive,
// switch_to). That function names its objects and calls Erx_trace::record,
// which fills an entry and hands it to the C17 core's erx_trace_kernel_put for
// the current CPU's ring. Every hook runs with interrupts masked, so record
// takes no lock of its own. The hooks' files see no core header: the event
// numbers stay in this file. The rings themselves are
// C (kernel/core/trace_rings.c) and reach this file only through the seam,
// erx/core/trace_kernel.h.
INTERFACE:

#include "types.h"

class Context;
class Task;

class Erx_trace
{
  // Only the handoff's banner decides the boot's erx.trace.
  friend class Erx_handoff;

  // Whether this boot writes the rings (erx.trace): set once by boot(), on the
  // boot CPU before any other CPU runs, and only read after.
  static bool _on;
};

IMPLEMENTATION:

#include "erx/core/abi_stop.h"  // ERX_PAGE_SIZE: the glue sees the subjects' headers, not erx/abi.h
#include "erx/core/clock_ns.h"
#include "erx/core/trace_kernel.h"
#include "erx/core/trace_window.h"
#include "config.h"
#include "context.h"
#include "cpu_lock.h"
#include "generic_timer.h"
#include "globals.h"
#include "mem_space.h"
#include "platform_control_object.h"
#include "task.h"
#include "thread.h"
#include "timer.h"

// A CPU number the glue passes always names a ring.
static_assert(Config::Max_num_cpus <= ERX_TRACE_KERNEL_RINGS,
              "the kernel has more CPUs than trace rings");

// The rings are padded and aligned to erXos's page (kernel/core/trace_rings.c), and
// map_trace maps them in Fiasco's: were Fiasco's larger, the window would show the
// kernel data beside them.
static_assert((1UL << Config::PAGE_SHIFT) == ERX_PAGE_SIZE,
              "Fiasco's page is erXos's, which the rings are padded to");

static_assert(static_cast<Mword>(Platform_control_object::Op::Erx_map_trace) == ERX_FIASCO_PFC_MAP_TRACE,
              "map_trace's operation number is the core's");

bool Erx_trace::_on;

// This boot's erx.trace, as erx_boot_args_trace decided it from the command
// line and the image's form (Erx_handoff::banner).
PRIVATE static
void
Erx_trace::boot(bool on)
{
  _on = on;
}

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
// addresses it stores through. Its caller holds the CPU lock (both hooks run
// on kernel paths with interrupts masked), so no interrupt enters the write
// and the CPU is its ring's one writer; an event on a path with interrupts
// enabled takes lock_guard(cpu_lock) around its call.
PRIVATE static
void
Erx_trace::record(Unsigned32 event, Unsigned64 arg0, Unsigned64 arg1,
                  Unsigned64 arg2)
{
  // A hook that reached here without the CPU lock would let an interrupt's
  // hook nest inside this write and leave one slot with two events' fields;
  // it writes nothing instead (the build defines NDEBUG, so no assert).
  if (!cpu_lock.test())
    return;
  Context const *running = current();
  erx_trace_entry_t entry{};

  // The counter is read with no ISB around it: the kernel entry and exit
  // around every hook are context synchronization events (SCTLR_EL1.EIS and
  // EOS, set by Cpu::Sctlr_res), so no read here moves past a user-mode
  // instruction of the root, and erx_trace_kernel_put keeps a ring's times in
  // order within one entry. The frequency is the one the boot CPU read, which
  // every CPU's matches, not a read of CNTFRQ_EL0 (docs/design-fiasco.md,
  // "The kernel's trace rings", "Writing").
  Unsigned64 const ticks = Generic_timer::Gtimer::counter();
  entry.time_ns = erx_clock_ticks_ns(ticks, Timer::counter_frequency());
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
  if (!_on)
    return;
  record(ERX_TRACE_EVENT_IPC_RECEIVE, trace_thread_id(sender),
         trace_thread_id(receiver), tag);
}

// The CPU switches to next (Context::_switch_exec_common).
PUBLIC static
void
Erx_trace::switch_to(Context const *next)
{
  if (!_on)
    return;
  record(ERX_TRACE_EVENT_SWITCH, trace_thread_id(next), trace_space_id(next), 0);
}

// map_trace on the platform control object (docs/design-fiasco.md, "The
// kernel's trace rings", "The root's window"): maps the rings' pages read-only
// at the window's base in caller's own space, once in a boot. The platform
// control object decodes the message (Platform_control_object::sys_erx_map_trace):
// words is its word count, and mempage, base and order its flexpage. Holding
// that object is the authority, and only the root holds it.
// erx_fiasco_trace_window decides; this maps. Answers the number of rings
// mapped, or Fiasco's negative error: -L4_ENOSYS on a boot whose rings are
// off (erx.trace), -L4_EINVAL for a malformed call or
// window, -L4_EEXIST once the rings are mapped, or the map's own failure.
PUBLIC static
long
Erx_trace::map_trace(Task *caller, unsigned words, bool mempage, Address base,
                     unsigned order)
{
  if (!_on)
    return -L4_err::ENosys;

  size_t bytes = 0;
  (void)erx_trace_kernel_pages(&bytes);
  erx_trace_window_call_t call{};
  erx_trace_window_limits_t limits{};

  call.words = words;
  call.mempage = mempage;
  call.base = base;
  call.order = order;
  call.mapped = !erx_trace_kernel_window_claim();
  limits.user_last = Mem_space::max_usable_user_address();
  limits.page_order = Config::PAGE_SHIFT;
  limits.rings_bytes = bytes;

  erx_trace_window_t const decided = erx_fiasco_trace_window(&call, &limits);
  if (decided.verdict == ERX_TRACE_WINDOW_MAPPED)
    return -L4_err::EExists;

  int const mapped = decided.verdict == ERX_TRACE_WINDOW_MAP
    ? caller->erx_map_trace_rings(static_cast<Address>(decided.base))
    : -L4_err::EInval;
  if (mapped < 0)
    {
      erx_trace_kernel_window_release();
      return mapped;
    }
  return ERX_TRACE_KERNEL_RINGS;
}

// The rings' pages and their size in bytes, for Task::erx_map_trace_rings,
// which maps them and nothing else.
PUBLIC static
void *
Erx_trace::rings_pages(size_t *bytes)
{
  return const_cast<void *>(erx_trace_kernel_pages(bytes));
}
