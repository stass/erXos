// Modified by erXos: a CPU's start ends in its admission to the stop of the
// machine (docs/design-debugger.md, "Stopping every CPU"); and a test kernel's
// seeded panic on CPU 2 (ERX_TEST_MACHINE_STOP, tools/lib/erx/native_machine_stop.rb),
// which no other kernel builds.
INTERFACE [mp]:

#include "kernel_thread.h"

class App_cpu_thread : public Kernel_thread
{
private:
  [[noreturn]] void bootstrap(Mword resume) asm ("call_ap_bootstrap")
         FIASCO_FASTCALL;
};

IMPLEMENTATION [mp]:

#include "erx_machine_stop.h"
#include "panic.h"
#include "timer.h"

#include <cstdlib>
#include <cstdio>

#include "config.h"
#include "delayloop.h"
#include "fpu.h"
#include "globals.h"
#include "helping_lock.h"
#include "kernel_task.h"
#include "processor.h"
#include "rcupdate.h"
#include "scheduler.h"
#include "task.h"
#include "thread.h"
#include "thread_state.h"
#include "timer.h"
#include "timer_tick.h"
#include "spin_lock.h"
#include "warn.h"

PUBLIC explicit inline
App_cpu_thread::App_cpu_thread(Ram_quota *q)
: Kernel_thread(q)
{}

PUBLIC static
Kernel_thread *
App_cpu_thread::may_be_create(Cpu_number cpu, bool cpu_never_seen_before)
{
  if (!cpu_never_seen_before)
    {
      kernel_context(cpu)->reset_kernel_sp();
      return static_cast<Kernel_thread *>(kernel_context(cpu));
    }

  Kernel_thread *t = Thread_object::create<App_cpu_thread>(Ram_quota::root);
  assert (t);

  t->set_home_cpu(cpu);
  t->set_current_cpu(cpu);
  t->kbind(Kernel_task::kernel_task());
  return t;
}


// the kernel bootstrap routine
IMPLEMENT
void
App_cpu_thread::bootstrap(Mword resume)
{
  extern Spin_lock<Mword> _tramp_mp_spinlock;

  state_change_dirty(0, Thread_ready);		// Set myself ready
  auto ccpu = current_cpu();

  Fpu::init(ccpu, resume);
  // Note: The FPU state of a kernel idle thread is irrelevant,
  //       so no need to restore it on resume.

  // initialize the current_mem_space function to point to the kernel space
  Kernel_task::kernel_task()->make_current();

  Mem_unit::tlb_flush();

  Cpu::cpus.current().set_present();
    {
      auto guard = lock_guard(_pending_rqq.current().q_lock());
      Cpu::cpus.current().set_online();
    }

  // Release _tramp_mp_spinlock without releasing CPU lock.
  _tramp_mp_spinlock.set(1);

  if (!resume)
    {
      kernel_context(ccpu, this);
      Sched_context::rq.current().set_idle(this->sched());

      Timer_tick::setup(ccpu);
    }

  Rcu::leave_idle(ccpu);
  Mem_space::enable_tlb(ccpu);

  if (!resume)
    // Setup initial timeslice
    Sched_context::rq.current().set_current_sched(sched());

  if (!resume)
    Per_cpu_data::run_late_ctors(ccpu);

  Scheduler::scheduler->trigger_hotplug_event();
  Timer_tick::enable(ccpu);
  Erx_machine_stop::admit();
  cpu_lock.clear();

#ifdef ERX_TEST_MACHINE_STOP
  // The test kernel of tools/lib/erx/native_machine_stop.rb only: CPU 2
  // panics once the boot has had time to start every CPU and the root task,
  // so its run shows the stop asking the others.
  if (!resume && ccpu == Cpu_number(2))
    {
      printf("erx: machine stop seed\n");
      while (Timer::system_clock() < 3000000)
        Proc::pause();
      panic("machine stop seed on CPU 2");
    }
#endif

  if (!resume)
    {
      Cpu::cpus.current().print_infos();
      WARNX(Info,"CPU[%u]: goes to idle loop\n",
                 cxx::int_value<Cpu_number>(ccpu));
    }

  init_workload();

  for (;;)
    idle_op();
}

PRIVATE
void
App_cpu_thread::init_workload()
{
  extern void (*_init_workload_app_cpu_table[])();
  for (unsigned i = 0; _init_workload_app_cpu_table[i]; ++i)
    _init_workload_app_cpu_table[i]();
}
