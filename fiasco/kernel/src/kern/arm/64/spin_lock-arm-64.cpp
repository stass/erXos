// Modified by erXos: the unlock signals an event, so a waiter in WFE wakes on an
// emulator that does not wake it for the store (docs/design-fiasco.md, "Patches").
INTERFACE [arm && mp]:

EXTENSION class Spin_lock
{
  static_assert(   sizeof(Lock_t) == 1 || sizeof(Lock_t) == 2
                || sizeof(Lock_t) == 4 || sizeof(Lock_t) == 8,
                "unsupported spin-lock type for ARM");
};

IMPLEMENTATION [arm && mp]:

#include "processor.h"

IMPLEMENT template<typename Lock_t> inline NEEDS["processor.h"]
void
Spin_lock<Lock_t>::lock_arch()
{
  Lock_t reg;
  Unsigned32 status;

#define LOCK_ARCH(z,u) \
  __asm__ __volatile__ ( \
      "   sevl                                       \n" \
      "   prfm pstl1keep, %[lock]                    \n" \
      "1: wfe                                        \n" \
      "   ldaxr" #z "  %" #u "[r], %[lock]           \n" \
      "   tst     %x[r], #2                          \n" /* Arch_lock == #2 */ \
      "   bne 1b                                     \n" \
      "   orr   %x[r], %x[r], #2                     \n" \
      "   stxr" #z " %w[status], %" #u "[r], %[lock] \n" \
      "   cbnz  %w[status], 1b                       \n" \
      : [r] "=&r" (reg),                                 \
        [status] "=&r"(status),                          \
        [lock] "+Q" (_lock)                              \
      : : "cc", "memory" )

  switch (sizeof(Lock_t))
    {
    case 1: LOCK_ARCH(b,w); break;
    case 2: LOCK_ARCH(h,w); break;
    case 4: LOCK_ARCH(,w); break;
    case 8: LOCK_ARCH(,x); break;
    }

#undef LOCK_ARCH
}

/*
 * The store clears the exclusive monitor of every waiter in lock_arch()'s WFE,
 * which wakes it on ARMv8 hardware. Under QEMU's TCG a waiter was seen asleep in
 * that WFE with the lock free, until an interrupt became pending; a waiter inside
 * the one-shot timer's handler, with that timer masked, may have none coming. The
 * SEV wakes the waiters without the monitor. It has no DSB before it, as the
 * pre-ARMv8 ARM32 unlock has: on hardware the monitor's wake covers a waiter that
 * the SEV woke too early, and the emulator is relied on to make the store
 * visible before the SEV's wake arrives.
 */
IMPLEMENT template<typename Lock_t> inline
void
Spin_lock<Lock_t>::unlock_arch()
{
  Lock_t tmp;

#define UNLOCK_ARCH(z,u) \
  __asm__ __volatile__( \
      "ldr"#z " %" #u "[tmp], %[lock]              \n" \
      "bic %x[tmp], %x[tmp], #2                    \n" /* Arch_lock == #2 */ \
      "stlr"#z " %" #u "[tmp], %[lock]             \n" \
      "sev                                         \n" \
      : [lock] "+Q" (_lock), [tmp] "=&r" (tmp) : : "memory")

  switch (sizeof(Lock_t))
    {
    case 1: UNLOCK_ARCH(b,w); break;
    case 2: UNLOCK_ARCH(h,w); break;
    case 4: UNLOCK_ARCH(,w); break;
    case 8: UNLOCK_ARCH(,x); break;
    }

#undef UNLOCK_ARCH
}
