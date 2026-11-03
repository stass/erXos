// Modified by erXos: the stopgap admits trusted code only, and the banner
// runs the C17 cores' link probe.
INTERFACE:

#include "initcalls.h"

class Banner
{
};

IMPLEMENTATION:

#include <cstdio>
#include "config.h"
#include "erx_probe.h"

PUBLIC static FIASCO_INIT
void
Banner::init()
{
  // Kip::k() has not necessarily been initialized yet!
  extern char _initkip_start[];
  printf("\n%s\n", _initkip_start);
  printf("development build: trusted code only\n");
  Erx_probe::run();

  if constexpr (Config::kernel_warn_config_string()
                && *Config::kernel_warn_config_string())
    printf("\033[31mPerformance-critical config option(s) detected:\n"
	   "%s\033[m\n", Config::kernel_warn_config_string());
}
