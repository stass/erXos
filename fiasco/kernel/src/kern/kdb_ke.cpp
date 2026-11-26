// Modified by erXos: without the kernel debugger, kdb_ke enters the stop of
// the machine (docs/design-debugger.md, "On Fiasco").
IMPLEMENTATION[!debug]:

#include "erx_machine_stop.h"

inline NEEDS ["erx_machine_stop.h"]
void kdb_ke(char const *msg)
{
  Erx_machine_stop::stop("%s", msg);
}

inline void kdb_ke_sequence(char const *, unsigned) {}
