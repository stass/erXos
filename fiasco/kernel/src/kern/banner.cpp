// Modified by erXos: it boots from erXos's boot image (docs/design-stopgap.md, "Boot handoff").
// Modified by erXos: the banner reports the boot image bootstrap validated.
INTERFACE:

#include "initcalls.h"

class Banner
{
};

IMPLEMENTATION:

#include <cstdio>
#include "config.h"
#include "erx_handoff.h"

PUBLIC static FIASCO_INIT
void
Banner::init()
{
  // Kip::k() has not necessarily been initialized yet!
  extern char _initkip_start[];
  printf("\n%s\n", _initkip_start);
  Erx_handoff::banner();

  if constexpr (Config::kernel_warn_config_string()
                && *Config::kernel_warn_config_string())
    printf("\033[31mPerformance-critical config option(s) detected:\n"
	   "%s\033[m\n", Config::kernel_warn_config_string());
}
