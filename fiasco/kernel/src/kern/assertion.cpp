// Modified by erXos: a failed assertion enters the stop of the machine
// (docs/design-debugger.md, "On Fiasco").
IMPLEMENTATION:

#include <cassert>
#include <cstdio>
#include <stdlib.h>

#include "erx_machine_stop.h"
#include "kernel_console.h"
#include "thread.h"

extern "C"
void
assert_fail(char const *expr_msg, char const *file, unsigned int line,
            void const *caller)
{
  Erx_machine_stop::stop("Assertion failed at %s:%u:%p: %s", file, line, caller, expr_msg);
}

