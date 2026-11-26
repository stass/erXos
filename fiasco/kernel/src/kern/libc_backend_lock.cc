// Modified by erXos: the stop's bounded take of the printf lock
// (docs/design-debugger.md, "The console's lock on Fiasco").
#include <libc_backend.h>

#include <atomic.h>
#include <cpu_lock.h>
#include "mem.h"
#include "processor.h"
#include "global_data.h"

static DEFINE_GLOBAL_CONSTINIT
Global_data<Mword> __libc_backend_printf_spinlock(~0UL);

extern "C" void __libc_backend_printf_local_force_unlock()
{
  Mword pid = cxx::int_value<Cpu_phys_id>(Proc::cpu_id());
  if (__libc_backend_printf_spinlock == pid)
    write_now(&__libc_backend_printf_spinlock, ~0UL);
}

extern "C" unsigned int __libc_backend_printf_lock()
{
  unsigned int r = cpu_lock.test() ? 1 : 0;
  cpu_lock.lock();

  Mword pid = cxx::int_value<Cpu_phys_id>(Proc::cpu_id());

  // support nesting
  if (__libc_backend_printf_spinlock == pid)
    return r | 2;

  for (;;)
    {
      Proc::pause();
      auto x = access_once(&__libc_backend_printf_spinlock);
      if (x != ~0UL)
        continue;

      if (cas(&__libc_backend_printf_spinlock, ~0UL, pid))
        return r;
    }
}

// The stop's take (docs/design-debugger.md, "The stop", step 6): the same
// compare-and-swap at most tries times, with interrupts already masked.
// Nonzero if this CPU holds the lock, already or now. The stop never gives it
// back, and a failed take is the stop's best-effort output, never a wait.
extern "C" int __libc_backend_printf_take_bounded(unsigned tries)
{
  Mword pid = cxx::int_value<Cpu_phys_id>(Proc::cpu_id());

  if (access_once(&__libc_backend_printf_spinlock) == pid)
    return 1;

  for (unsigned i = 0; i < tries; ++i)
    {
      if (access_once(&__libc_backend_printf_spinlock) == ~0UL
          && cas(&__libc_backend_printf_spinlock, ~0UL, pid))
        return 1;
      Proc::pause();
    }
  return 0;
}

extern "C" void __libc_backend_printf_unlock(unsigned int state)
{
  if (!(state & 2))
    write_now(&__libc_backend_printf_spinlock, ~0UL);

  if (!(state & 1))
    cpu_lock.clear();

  Mem::mp_wmb();
}
