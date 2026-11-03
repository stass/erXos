#pragma once

#include "mem_v7plus.h"

namespace Arm
{
class Internal
{
public:
  static inline unsigned long get_clidr()
  {
    unsigned long clidr;
    asm volatile("mrc p15, 1, %0, c0, c0, 1" : "=r" (clidr));
    return clidr;
  }

  static inline void dc_cisw(unsigned long v)
  {
    asm volatile("mcr p15, 0, %0, c7, c14, 2" : : "r" (v) : "memory");
  }

  static inline void dc_csw(unsigned long v)
  {
    asm volatile("mcr p15, 0, %0, c7, c10, 2" : : "r" (v) : "memory");
  }

  static inline void dc_isw(unsigned long v)
  {
    asm volatile("mcr p15, 0, %0, c7, c6, 2" : : "r" (v) : "memory");
  }

  static inline void ic_iallu()
  {
    asm volatile("ic iallu" : : : "memory");
  }

  static inline unsigned long get_ccsidr(unsigned long csselr)
  {
    unsigned long ccsidr;
    asm volatile("mcr p15, 2, %0, c0, c0, 0" : : "r" (csselr));
    Barrier::isb();
    asm volatile("mrc p15, 1, %0, c0, c0, 0" : "=r" (ccsidr));
    return ccsidr;
  }

  static unsigned linesize_bytes()
  {
    return 1 << ((get_ccsidr(0 /* L1 data or unified */) & 7) + 4);
  }

  static bool hyp_mode()
  {
    unsigned long cpsr;
    asm("mrs %0, cpsr" : "=r"(cpsr));
    return (cpsr & 0x1fU) == 0x1aU;
  }

  static unsigned long sctlr()
  {
    unsigned long sctlr;

    if (hyp_mode())
      asm volatile("mrc p15, 4, %0, c1, c0, 0" : "=r"(sctlr)); // HSCTLR
    else
      asm volatile("mrc p15, 0, %0, c1, c0, 0" : "=r"(sctlr)); // SCTLR

    return sctlr;
  }

  static void sctlr(unsigned long sctlr)
  {
    if (hyp_mode())
      asm volatile("mcr p15, 4, %0, c1, c0, 0" : : "r"(sctlr) : "memory"); // HSCTLR
    else
      asm volatile("mcr p15, 0, %0, c1, c0, 0" : : "r"(sctlr) : "memory"); // SCTLR
  }
};

} // namespace Arm

void Cache::Data::clean()
{
  Arm_v7plus::set_way_full_loop(Arm::Internal::dc_csw,
                                Arm::Internal::get_clidr,
                                Arm::Internal::get_ccsidr,
                                Arm_v7plus::set_way_dcache_noinfo_op());
}

void Cache::Data::clean(unsigned long addr)
{
  asm volatile("mcr p15, 0, %0, c7, c10, 1" : : "r" (addr) : "memory"); // DCCMVAC
  Barrier::dsb_system();
}

void Cache::Data::clean(unsigned long start, unsigned long size)
{
  unsigned long cl_size = Arm::Internal::linesize_bytes();
  unsigned long m = start & ~(cl_size - 1);
  unsigned long e = (start + size + cl_size - 1) & ~(cl_size - 1);
  asm volatile("" : : : "memory");
  for (; m != e; m += cl_size)
    asm volatile("mcr p15, 0, %0, c7, c10, 1" : : "r" (m));
  Barrier::dsb_system();
}

void Cache::Data::inv()
{
  Arm_v7plus::set_way_full_loop(Arm::Internal::dc_isw,
                                Arm::Internal::get_clidr,
                                Arm::Internal::get_ccsidr,
                                Arm_v7plus::set_way_dcache_noinfo_op());
}

void Cache::Data::inv(unsigned long addr)
{
  asm volatile("mcr p15, 0, %0, c7, c6, 1" : : "r" (addr) : "memory"); // DCIMVAC
  Barrier::dsb_system();
}

void Cache::Data::flush()
{
  Arm_v7plus::set_way_full_loop(Arm::Internal::dc_cisw,
                                Arm::Internal::get_clidr,
                                Arm::Internal::get_ccsidr,
                                Arm_v7plus::set_way_dcache_noinfo_op());
}

void Cache::Data::flush(unsigned long addr)
{
  asm volatile("mcr p15, 0, %0, c7, c14, 1" : : "r" (addr) : "memory"); // DCCIMVAC
  Barrier::dsb_system();
}

bool Cache::Data::enabled()
{
  return Arm::Internal::sctlr() & (1UL << 2);
}

void Cache::Data::enable()
{
  Barrier::dsb_system();
  Arm::Internal::sctlr(Arm::Internal::sctlr() | (1UL << 2));
  Barrier::isb();
}

void Cache::Data::disable()
{
  Barrier::dsb_system();
  Arm::Internal::sctlr(Arm::Internal::sctlr() & ~(1UL << 2));
  Barrier::isb();
}

void Cache::Insn::enable()
{
  inv();
  Arm::Internal::sctlr(Arm::Internal::sctlr() | (1UL << 12));
  Barrier::isb();
}

void Cache::Insn::disable()
{
  Arm::Internal::sctlr(Arm::Internal::sctlr() & ~(1UL << 12));
  Barrier::isb();
  inv();
}

void Cache::Insn::inv()
{
  asm volatile("mcr p15, 0, %0, c7, c5, 0" : : "r" (0) : "memory"); // ICIALLU
  Barrier::dsb_system();
  Barrier::isb();
}
