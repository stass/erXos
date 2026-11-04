// Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
// SPDX-License-Identifier: BSD-2-Clause
//
// The kernel side of erXos's kernel call on the stopgap (docs/design-stopgap.md,
// "Transport"): the fork's system-call trap hands a call made with erXos's trap
// immediate here. This file copies the registers out of the frame into a
// private snapshot, names the caller, and lets the cores decide; it decides
// nothing itself and reads no user-writable memory. Every other trap immediate
// stays on Fiasco's own path.
INTERFACE:

#include "types.h"

class Trap_state;

/**
 * What a space holds for the kernel log: its number in log lines and its
 * opaque log rate state, which starts out zeroed and which only the cores
 * read or write, under the log lock.
 */
class Erx_space_log
{
public:
  Erx_space_log();

  Unsigned64 number() const { return _number; }
  void *rate() { return _rate; }

  enum { Rate_words = 3 };

private:
  Unsigned64 _number;
  Unsigned64 _rate[Rate_words] = { 0, 0, 0 };
};

class Erx_syscall
{
public:
  /** Whether an AArch64 system-call syndrome names erXos's trap immediate. */
  static bool is_call(Mword syndrome);

  /**
   * Runs one kernel call made from user mode by the current thread, with
   * interrupts masked from the exception's entry to its return.
   */
  static void enter(Trap_state *ts);
};

IMPLEMENTATION:

#include "erx/core/abi_trap.h"
#include "erx/core/dispatch.h"
#include "erx/core/effects.h"
#include "global_data.h"
#include "globals.h"
#include "kernel_console.h"
#include "space.h"
#include "spin_lock.h"
#include "thread.h"
#include "timer.h"
#include "trap_state.h"

static_assert(sizeof(Utcb) == ERX_TRAP_UTCB_BYTES, "Fiasco's Utcb is erx_utcb");
static_assert(Erx_space_log::Rate_words * sizeof(Unsigned64) == ERX_LOG_RATE_STATE_BYTES,
              "a space's log rate storage");
static_assert(alignof(Unsigned64) == ERX_LOG_RATE_STATE_ALIGN,
              "a space's log rate alignment");

// The immediate of a system-call syndrome, in its low bits.
enum { Erx_syndrome_immediate_mask = 0xffff };

static DEFINE_GLOBAL Global_data<Spin_lock<>> erx_log_lock;
static Spin_lock<>::Status erx_log_lock_status;
static Unsigned64 erx_space_log_next;

IMPLEMENT
Erx_space_log::Erx_space_log()
: _number(__atomic_add_fetch(&erx_space_log_next, 1, __ATOMIC_RELAXED))
{}

IMPLEMENT
bool
Erx_syscall::is_call(Mword syndrome)
{
  return (syndrome & Erx_syndrome_immediate_mask) == ERX_TRAP_IMMEDIATE;
}

IMPLEMENT
void
Erx_syscall::enter(Trap_state *ts)
{
  static unsigned const arg_registers[] = ERX_TRAP_REG_ARGS;
  static unsigned const result_registers[] = ERX_TRAP_REG_RESULTS;
  uint64_t args[ERX_TRAP_ARG_COUNT];
  uint64_t results[ERX_TRAP_RESULT_COUNT];
  Thread *thread = current_thread();

  for (unsigned i = 0; i < ERX_TRAP_ARG_COUNT; ++i)
    args[i] = ts->r[arg_registers[i]];

  Erx_space_log &log = thread->space()->erx_log;
  erx_sys_caller_t caller = {};
  // The kernel's own mapping of the UTCB, never the address user mode knows.
  caller.utcb = thread->utcb().kern();
  caller.log_rate = log.rate();
  caller.space = log.number();
  // No thread on the fork is an executor: its threads have no grant class.
  caller.executor = false;

  erx_dispatch(&caller, ts->r[ERX_TRAP_REG_NUMBER], args, results);

  for (unsigned i = 0; i < ERX_TRAP_RESULT_COUNT; ++i)
    ts->r[result_registers[i]] = results[i];
}

// The effects of the debug-log core.

extern "C" void
erx_effect_log_lock(void)
{
  Spin_lock<>::Status status = erx_log_lock->test_and_set();
  erx_log_lock_status = status;
}

extern "C" void
erx_effect_log_unlock(void)
{
  erx_log_lock->set(erx_log_lock_status);
}

extern "C" uint64_t
erx_effect_clock_ns(void)
{
  return Timer::system_clock() * 1000;
}

extern "C" void
erx_effect_console_write(char const *line, size_t length)
{
  Kconsole::console()->write(line, length);
}
