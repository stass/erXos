// Modified by erXos: it boots from erXos's boot image (docs/design-stopgap.md, "Boot handoff").

#include <l4/sys/compiler.h>

#include "support.h"
#include "platform.h"
#include "startup.h"

struct boot_args boot_args;

extern "C" void __main(unsigned long r0, unsigned long r1,
                       unsigned long r2, unsigned long r3);
void __main(unsigned long r0, unsigned long r1,
            unsigned long r2, unsigned long r3)
{
  // Ensure all is masked, irrespective of what our bootloader selected.
  asm("msr daif, %0" : : "r" (0x3c0UL));

  clear_bss();

  boot_args.r[0] = r0;
  boot_args.r[1] = r1;
  boot_args.r[2] = r2;
  boot_args.r[3] = r3;

  ctor_init();
  Platform_base::iterate_platforms();

  startup(nullptr);
  l4_infinite_loop();
}
