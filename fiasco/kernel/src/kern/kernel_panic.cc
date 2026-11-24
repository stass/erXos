// Modified by erXos: a panic closes the ring console's route before its report
// (docs/design-fiasco.md, "The kernel's lines").
#include <cassert>
#include <cstdarg>
#include <cstdio>
#include <cstdlib>
#include <panic.h>

#include "erx_console_ring.h"
#include "kernel_console.h"
#include "simpleio.h"
#include "thread.h"

extern "C"
void
panic(const char *format, ...)
{
  Erx_console_ring::close();

  // make sure that GZIP mode is off
  Kconsole::console()->end_exclusive(Console::GZIP);

  va_list args;

  putstr("\033[1mPanic: ");
  va_start (args, format);
  vprintf  (format, args);
  va_end   (args);
  puts("\033[m");

  Thread::system_abort();
}
