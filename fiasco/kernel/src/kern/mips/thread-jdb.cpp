// Modified by erXos: the kernel debugger's parts are deleted (docs/design-debugger.md).
/*
 * Copyright (C) 2014 Imagination Technologies Ltd.
 * Author: Sanjay Lal <sanjayl@kymasys.com>
 * Author: Yann Le Du <ledu@kymasys.com>
 * Author: Alexander Warg <alexander.warg@kernkonzept.com>
 */

IMPLEMENTATION [mips && !debug]:

extern "C" void sys_kdb_ke()
{}

PUBLIC static inline
int
Thread::call_nested_trap_handler(Trap_state *)
{ return -1; }
