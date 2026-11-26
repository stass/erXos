// Modified by erXos: the kernel debugger's parts are deleted (docs/design-debugger.md).
INTERFACE:

#include "types.h"

class Ipi
{
public:
  static void init(Cpu_number cpu);
};

INTERFACE[!mp]:

EXTENSION class Ipi
{
public:
  enum Message { Request, Global_request, Debug };
};

INTERFACE[mp]:

#include "per_cpu_data.h"
#include "spin_lock.h"

EXTENSION class Ipi
{
private:
  static Per_cpu<Ipi> _ipi;
};

// ------------------------------------------------------------------------
IMPLEMENTATION[!mp]:

IMPLEMENT inline
void
Ipi::init(Cpu_number /* cpu */)
{}

PUBLIC static inline
void
Ipi::send(Message, Cpu_number /* from_cpu */, Cpu_number /* to_cpu */)
{}

PUBLIC static inline
void
Ipi::eoi(Message, Cpu_number /* on_cpu */)
{}

PUBLIC static inline
void
Ipi::bcast(Message, Cpu_number /* from_cpu */)
{}

PUBLIC static inline
void
Ipi::self(Message)
{}


// ------------------------------------------------------------------------
IMPLEMENTATION[mp]:

DEFINE_PER_CPU Per_cpu<Ipi> Ipi::_ipi;

// ------------------------------------------------------------------------
IMPLEMENTATION[!(mp && debug)]:

PUBLIC static inline
void
Ipi::stat_sent(Cpu_number /* from_cpu */)
{}

PUBLIC static inline
void
Ipi::stat_received(Cpu_number /* on_cpu */)
{}

// ------------------------------------------------------------------------
