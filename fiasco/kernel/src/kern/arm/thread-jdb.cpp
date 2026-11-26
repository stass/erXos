// Modified by erXos: the kernel debugger's parts are deleted (docs/design-debugger.md).
// Modified by erXos: without JDB a kernel-mode trap enters the machine stop,
// which stops every CPU, records and resets (docs/design-debugger.md, "Causes").
INTERFACE [arm]:

EXTENSION class Thread
{
protected:
  /**
   * Call a trap handler supposed to enter a debugger.
   * Use a separate stack (per-CPU dbg_stack).
   *
   * \param ts  Trap state.
   * \retval 0 trap has been consumed by the handler.
   * \retval -1 trap could not be handled.
   * Without JDB it does not return: it panics.
   */
  static int call_nested_trap_handler(Trap_state *ts) asm ("call_nested_trap_handler");
  static int arm_serror_handler(Trap_state *ts) asm ("arm_serror_handler");
};

IMPLEMENTATION [arm]:

#include "globals.h"

IMPLEMENT
int
Thread::arm_serror_handler(Trap_state *)
{
  ++(num_serrors.cpu(current_cpu()));
  return 0;
}

//-----------------------------------------------------------------------------
IMPLEMENTATION [arm-!debug]:

#include "erx_machine_stop.h"

// Without JDB a kernel-mode trap is fatal as it is with JDB, which stops
// every CPU: the machine stop takes the trap's frame and resets the machine.
// Returning to the faulting instruction would only trap again on this CPU
// while the others run on.
IMPLEMENT
int
Thread::call_nested_trap_handler(Trap_state *ts)
{
  Erx_machine_stop::trap(ts, "kernel trap");
}
