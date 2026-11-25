/* Modified by erXos: the minimal libc, the only one erXos builds, keeps
 * errno in one static variable; there is no libpthread thread descriptor
 * to hold it. */
#include <errno.h>

static int _errnoval;

int *__errno_location(void)
{
  return &_errnoval;
}

weak_alias(__errno_location, ___errno_location);
