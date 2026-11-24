// Modified by erXos: a failed assertion closes the ring console's route before its
// report (docs/design-fiasco.md, "The kernel's lines").
IMPLEMENTATION:

#include <cassert>
#include <cstdio>
#include <stdlib.h>

#include "erx_console_ring.h"
#include "kernel_console.h"
#include "thread.h"

extern "C"
void
assert_fail(char const *expr_msg, char const *file, unsigned int line,
            void const *caller)
{
  Erx_console_ring::close();

  // Make sure that GZIP mode is off.
  //
  // We need to use the console_unchecked() method here to avoid potential
  // infinite recursion (calling assert() in the regular console() method).
  Kconsole::console_unchecked()->end_exclusive(Console::GZIP);

  printf("\nAssertion failed at %s:%u:%p: %s\n", file, line, caller, expr_msg);

  Thread::system_abort();
}

