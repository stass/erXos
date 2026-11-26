// Modified by erXos: the kernel debugger's parts are deleted (docs/design-debugger.md).
INTERFACE [riscv]:

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
   */
  static int call_nested_trap_handler(Trap_state *ts);
};

//----------------------------------------------------------------------------
IMPLEMENTATION [riscv && !debug]:

IMPLEMENT
int
Thread::call_nested_trap_handler(Trap_state *ts)
{
  ts->dump();
  current_thread()->kill();
  return -1;
}
