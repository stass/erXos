// Modified by erXos: a panic enters the stop of the machine
// (docs/design-debugger.md, "On Fiasco").
#include <cassert>
#include <cstdarg>
#include <cstdio>
#include <cstdlib>
#include <panic.h>

#include "erx_machine_stop.h"
#include "kernel_console.h"
#include "simpleio.h"
#include "thread.h"

extern "C"
void
panic(const char *format, ...)
{
  va_list args;
  va_start(args, format);
  Erx_machine_stop::panic(format, args);
}
