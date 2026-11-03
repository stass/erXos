IMPLEMENTATION [arm && !arm_v6plus]:

#include "mem.h"

template<typename T> inline NEEDS["mem.h"]
bool
local_cas(T *mem, T oldval, T newval)
{
  Mem::barrier();
  bool res = cas_relaxed(mem, oldval, newval);
  Mem::barrier();
  return res;
}

inline
void
local_atomic_and(Mword *mem, Mword value)
{
  Mword old;
  do { old = *mem; }
  while (!local_cas(mem, old, old & value));
}

inline
void
local_atomic_or(Mword *mem, Mword value)
{
  Mword old;
  do { old = *mem; }
  while (!local_cas(mem, old, old | value));
}

//---------------------------------------------------------------------------
IMPLEMENTATION [arm && arm_v6plus]:

#include "mem.h"

template<typename T> inline NEEDS["mem.h"]
bool
local_cas(T *mem, T oldval, T newval)
{
  Mem::barrier();
  bool res = cas_relaxed(mem, oldval, newval);
  Mem::barrier();
  return res;
}

inline NEEDS["mem.h"]
void
local_atomic_or(Mword *mem, Mword value)
{
  Mem::barrier();
  atomic_or_relaxed(mem, value);
  Mem::barrier();
}

inline NEEDS["mem.h"]
void
local_atomic_and(Mword *mem, Mword value)
{
  Mem::barrier();
  atomic_and_relaxed(mem, value);
  Mem::barrier();
}
