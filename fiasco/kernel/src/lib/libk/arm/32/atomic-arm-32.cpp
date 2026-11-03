INTERFACE[arm && arm_v6plus]:

#include "mem.h"

// preprocess off
#define ATOMIC_OP(name, op)                                                    \
  template<typename T, typename V>                                             \
  requires(sizeof(T) == 4) inline                                              \
  void                                                                         \
  atomic_##name##_relaxed(T *mem, V value)                                     \
  {                                                                            \
    static_assert(cxx::is_integral_v<T>);                                      \
    T val = value;                                                             \
    T res;                                                                     \
    Mword tmp;                                                                 \
    Mem::prefetch_w(mem);                                                      \
    asm volatile (                                                             \
        "1:   ldrex %[res], %[mem] \n"                                         \
              #op " %[res], %[res], %[val] \n"                                 \
        "     strex %[tmp], %[res], %[mem] \n"                                 \
        "     teq   %[tmp], #0 \n"                                             \
        "     bne   1b "                                                       \
        : [res] "=&r" (res), [tmp] "=&r" (tmp), [mem] "+Q" (*mem)              \
        : [val] "r" (val)                                                      \
        : "cc");                                                               \
  }                                                                            \
                                                                               \
  template<typename T, typename V>                                             \
  requires(sizeof(T) == 4) inline                                              \
  T                                                                            \
  atomic_fetch_##name##_relaxed(T *mem, V value)                               \
  {                                                                            \
    static_assert(cxx::is_integral_v<T>);                                      \
    T val = value;                                                             \
    T res, old;                                                                \
    Mword tmp;                                                                 \
    Mem::prefetch_w(mem);                                                      \
    asm volatile (                                                             \
        "1:   ldrex %[old], %[mem] \n"                                         \
              #op " %[res], %[old], %[val] \n"                                 \
        "     strex %[tmp], %[res], %[mem] \n"                                 \
        "     teq   %[tmp], #0 \n"                                             \
        "     bne   1b "                                                       \
        : [res] "=&r" (res), [old] "=&r" (old), [tmp] "=&r" (tmp),             \
          [mem] "+Q" (*mem)                                                    \
        : [val] "r" (val)                                                      \
        : "cc");                                                               \
    return old;                                                                \
  }                                                                            \
                                                                               \
  template<typename T, typename V>                                             \
  requires(sizeof(T) == 4) inline                                              \
  T                                                                            \
  atomic_##name##_fetch_relaxed(T *mem, V value)                               \
  {                                                                            \
    static_assert(cxx::is_integral_v<T>);                                      \
    T val = value;                                                             \
    T res;                                                                     \
    Mword tmp;                                                                 \
    Mem::prefetch_w(mem);                                                      \
    asm volatile (                                                             \
        "1:   ldrex %[res], %[mem] \n"                                         \
              #op " %[res], %[res], %[val] \n"                                 \
        "     strex %[tmp], %[res], %[mem] \n"                                 \
        "     teq   %[tmp], #0 \n"                                             \
        "     bne   1b "                                                       \
        : [res] "=&r" (res), [tmp] "=&r" (tmp), [mem] "+Q" (*mem)              \
        : [val] "r" (val)                                                      \
        : "cc");                                                               \
    return res;                                                                \
  }
ATOMIC_OP(and, and)
ATOMIC_OP(or, orr)
ATOMIC_OP(add, add)
#undef ATOMIC_OP
// preprocess on

// --------------------------------------------------------------------
INTERFACE[arm && (arm_v7plus || (arm_v6 && mp))]:

// preprocess off
#define ATOMIC_OP(name, opl, oph)                                              \
  template<typename T, typename V>                                             \
  requires(sizeof(T) == 8) inline                                              \
  void                                                                         \
  atomic_##name##_relaxed(T *mem, V value)                                     \
  {                                                                            \
    static_assert(cxx::is_integral_v<T>);                                      \
    T val = value;                                                             \
    T res;                                                                     \
    Mword tmp;                                                                 \
    Mem::prefetch_w(mem);                                                      \
    asm volatile (                                                             \
        "1:   ldrexd %[res], %H[res], %[mem] \n"                               \
              #opl " %[res], %[res], %[val] \n"                                \
              #oph " %H[res], %H[res], %H[val] \n"                             \
        "     strexd %[tmp], %[res], %H[res], %[mem] \n"                       \
        "     teq    %[tmp], #0 \n"                                            \
        "     bne    1b "                                                      \
        : [res] "=&r" (res), [tmp] "=&r" (tmp), [mem] "+Q" (*mem)              \
        : [val] "r" (val)                                                      \
        : "cc");                                                               \
  }                                                                            \
                                                                               \
  template<typename T, typename V>                                             \
  requires(sizeof(T) == 8) inline                                              \
  T                                                                            \
  atomic_fetch_##name##_relaxed(T *mem, V value)                               \
  {                                                                            \
    static_assert(cxx::is_integral_v<T>);                                      \
    T val = value;                                                             \
    T res, old;                                                                \
    Mword tmp;                                                                 \
    Mem::prefetch_w(mem);                                                      \
    asm volatile (                                                             \
        "1:   ldrexd %[old], %H[old], %[mem] \n"                               \
              #opl " %[res], %[old], %[val] \n"                                \
              #oph " %H[res], %H[old], %H[val] \n"                             \
        "     strexd %[tmp], %[res], %H[res], %[mem] \n"                       \
        "     teq    %[tmp], #0 \n"                                            \
        "     bne    1b "                                                      \
        : [res] "=&r" (res), [old] "=&r" (old), [tmp] "=&r" (tmp),             \
          [mem] "+Q" (*mem)                                                    \
        : [val] "r" (val)                                                      \
        : "cc");                                                               \
    return old;                                                                \
  }                                                                            \
                                                                               \
  template<typename T, typename V>                                             \
  requires(sizeof(T) == 8) inline                                              \
  T                                                                            \
  atomic_##name##_fetch_relaxed(T *mem, V value)                               \
  {                                                                            \
    static_assert(cxx::is_integral_v<T>);                                      \
    T val = value;                                                             \
    T res;                                                                     \
    Mword tmp;                                                                 \
    Mem::prefetch_w(mem);                                                      \
    asm volatile (                                                             \
        "1:   ldrexd %[res], %H[res], %[mem] \n"                               \
              #opl " %[res], %[res], %[val] \n"                                \
              #oph " %H[res], %H[res], %H[val] \n"                             \
        "     strexd %[tmp], %[res], %H[res], %[mem] \n"                       \
        "     teq    %[tmp], #0 \n"                                            \
        "     bne    1b "                                                      \
        : [res] "=&r" (res), [tmp] "=&r" (tmp), [mem] "+Q" (*mem)              \
        : [val] "r" (val)                                                      \
        : "cc");                                                               \
    return res;                                                                \
  }
ATOMIC_OP(and, and, and)
ATOMIC_OP(or, orr, orr)
ATOMIC_OP(add, adds, adc)
#undef ATOMIC_OP
// preprocess on

//----------------------------------------------------------------------------
INTERFACE[arm && arm_v6plus]:

template<typename T, typename V>
requires(sizeof(T) == 4) inline
T
atomic_exchange_relaxed(T *mem, V value)
{
  T val = value;
  T res;
  Mword tmp;

  Mem::prefetch_w(mem);
  asm volatile (
      "1:   ldrex %[res], [%[mem]] \n"
      "     strex %[tmp], %[val], [%[mem]] \n"
      "     cmp   %[tmp], #0 \n"
      "     bne   1b "
      : [res] "=&r" (res), [tmp] "=&r" (tmp), "+Qo" (*mem)
      : [mem] "r" (mem), [val] "r" (val)
      : "cc");
  return res;
}

// --------------------------------------------------------------------
INTERFACE[arm && (arm_v7plus || (arm_v6 && mp))]:

template<typename T, typename V>
requires(sizeof(T) == 8) inline
T
atomic_exchange_relaxed(T *mem, V value)
{
  T val = value;
  T res;
  Mword tmp;
  Mem::prefetch_w(mem);
  asm volatile (
      "1:   ldrexd %[res], %H[res], %[mem] \n"
      "     strexd %[tmp], %[val], %H[val], %[mem] \n"
      "     cmp    %[tmp], #0 \n"
      "     bne    1b "
      : [res] "=&r" (res), [tmp] "=&r" (tmp), [mem] "+Q" (*mem)
      : [val] "r" (val)
      : "cc");
  return res;
}

// --------------------------------------------------------------------
INTERFACE[arm && arm_v6 && !mp]:

#include "processor.h"

template<typename T, typename V>
requires(sizeof(T) == 8) inline NEEDS ["processor.h"]
T
atomic_exchange_relaxed(T *mem, V value)
{
  Mword s = Proc::cli_save();
  T val = value;
  T res;
  Mem::prefetch_w(mem);
  asm volatile (
      "1:   ldrd %[res], %H[res], %[mem] \n"
      "     strd %[val], %H[val], %[mem]   "
      : [res] "=&r" (res), [mem] "+m" (*mem)
      : [val] "r" (val));
  Proc::sti_restore(s);
  return res;
}

template<typename T, typename V>
requires(sizeof(T) == 8) inline NEEDS ["processor.h"]
T
atomic_add_fetch_relaxed(T *mem, V value)
{
  static_assert(cxx::is_integral_v<T>);
  Mword s = Proc::cli_save();
  T val = value;
  T res;
  Mem::prefetch_w(mem);
  asm volatile (
      "1:   ldrd   %[res], %H[res], %[mem] \n"
      "     adds   %[res], %[res], %[val] \n"
      "     adc    %H[res], %H[res], %H[val] \n"
      "     strd   %[res], %H[res], %[mem]"
      : [res] "=&r" (res), [mem] "+m" (*mem)
      : [val] "r" (val)
      : "cc");
  Proc::sti_restore(s);
  return res;
}

// --------------------------------------------------------------------
INTERFACE[arm]:

template<typename T>
requires(sizeof(T) == 4) inline
T
atomic_load_relaxed(T const *p)
{
  T res;
  asm volatile ("ldr %0, %1" : "=r" (res) : "m"(*p));
  return res;
}

template<typename T, typename V>
requires(sizeof(T) == 4) inline
void
atomic_store_relaxed(T *p, V value)
{
  T val = value;
  asm volatile("str %1, %0" : "=m"(*p) : "r"(val));
}

// --------------------------------------------------------------------
INTERFACE[arm && arm_v6plus && (!mp || arm_lpae || arm_v8plus)]:

template<typename T>
requires(sizeof(T) == 8) inline
T
atomic_load_relaxed(T const *p)
{
  T res;
  asm volatile ("ldrd %0, %H0, %1" : "=r" (res) : "m" (*p));
  return res;
}

template<typename T, typename V>
requires(sizeof(T) == 8) inline
void
atomic_store_relaxed(T *p, V value)
{
  T val = value;
  asm volatile ("strd %1, %H1, %0" : "=m" (*p) : "r" (val));
}

// --------------------------------------------------------------------
INTERFACE[arm && arm_v6plus && mp && !arm_lpae && !arm_v8plus]:

template<typename T>
requires(sizeof(T) == 8) inline
T
atomic_load_relaxed(T const *p)
{
  T res;
  asm volatile ("ldrexd %0, %H0, [%1]" : "=r" (res) : "r" (p), "Qo" (*p));
  return res;
}

template<typename T, typename V>
requires(sizeof(T) == 8) inline
void
atomic_store_relaxed(T *p, V value)
{
  T val = value;
  long long tmp;
  Mem::prefetch_w(p);
  asm volatile (
      "1: ldrexd %0, %H0, [%2] \n"
      "   strexd %0, %3, %H3, [%2] \n"
      "   teq    %0, #0 \n"
      "   bne    1b"
      : "=&r"(tmp), "=Qo"(*p)
      : "r"(p), "r"(val)
      : "cc");
}

// --------------------------------------------------------------------
INTERFACE[arm && arm_v6plus]:

template<typename T> requires(sizeof(T) == 4) inline
bool
cas_relaxed(T *m, T o, T n)
{
  T tmp;
  Mword res;

  asm volatile
    ("mov     %[res], #1           \n"
     "1:                           \n"
     "ldr     %[tmp], [%[m]]       \n"
     "teq     %[tmp], %[o]         \n"
     "bne     2f                   \n"
     "ldrex   %[tmp], [%[m]]       \n"
     "teq     %[tmp], %[o]         \n"
     "strexeq %[res], %[n], [%[m]] \n"
     "teq     %[res], #1           \n"
     "beq     1b                   \n"
     "2:                           \n"
     : [tmp] "=&r" (tmp), [res] "=&r" (res), "+m" (*m)
     : [n] "r" (n), [m] "r" (m), [o] "r" (o)
     : "cc");

  // res == 0 is ok
  // res == 1 is failed

  return !res;
}

// --------------------------------------------------------------------
INTERFACE[arm && arm_v6plus]:

template<typename T> inline
T
atomic_load_acquire(T const *mem)
{
  T res = atomic_load_relaxed(mem);
  Mem::dmb();
  return res;
}

template<typename T> inline
T
atomic_load_seq_cst(T const *mem)
{
  Mem::dmb();
  T res = atomic_load_relaxed(mem);
  Mem::dmb();
  return res;
}

template<typename T, typename V> inline
void
atomic_store_release(T *mem, V value)
{
  Mem::dmb();
  atomic_store_relaxed(mem, value);
}

template<typename T, typename V> inline
void
atomic_store_seq_cst(T *mem, V value)
{
  Mem::dmb();
  atomic_store_relaxed(mem, value);
  Mem::dmb();
}

// preprocess off
#define WRAP_ATOMIC_OP_VOID(name, order, pre, post)                            \
  template<typename T, typename V>  inline                                     \
  void                                                                         \
  name##_##order(T *mem, V value)                                              \
  {                                                                            \
    pre;                                                                       \
    name ## _relaxed(mem, value);                                              \
    post;                                                                      \
  }

#define WRAP_ATOMIC_OP_RET(name, order, pre, post)                             \
  template<typename T, typename V>  inline                                     \
  T                                                                            \
  name##_##order(T *mem, V value)                                              \
  {                                                                            \
    pre;                                                                       \
    T res = name ## _relaxed(mem, value);                                      \
    post;                                                                      \
    return res;                                                                \
  }

#define WRAP_ATOMIC_OP_CAS(name, order, pre, post)                             \
  template<typename T> inline                                                  \
  bool                                                                         \
  name##_##order(T *mem, T oldval, T newval)                                   \
  {                                                                            \
    pre;                                                                       \
    bool res = name ## _relaxed(mem, oldval, newval);                          \
    post;                                                                      \
    return res;                                                                \
  }

#define ATOMIC_IMPL_VARIANTS(OP_MACRO, name)                                   \
  OP_MACRO(name, acquire,           , Mem::dmb())                              \
  OP_MACRO(name, release, Mem::dmb(),           )                              \
  OP_MACRO(name, acq_rel, Mem::dmb(), Mem::dmb())                              \
  OP_MACRO(name, seq_cst, Mem::dmb(), Mem::dmb())

ATOMIC_IMPL_VARIANTS(WRAP_ATOMIC_OP_VOID, atomic_and)
ATOMIC_IMPL_VARIANTS(WRAP_ATOMIC_OP_VOID, atomic_or)
ATOMIC_IMPL_VARIANTS(WRAP_ATOMIC_OP_VOID, atomic_add)
ATOMIC_IMPL_VARIANTS(WRAP_ATOMIC_OP_RET, atomic_fetch_and)
ATOMIC_IMPL_VARIANTS(WRAP_ATOMIC_OP_RET, atomic_fetch_or)
ATOMIC_IMPL_VARIANTS(WRAP_ATOMIC_OP_RET, atomic_fetch_add)
ATOMIC_IMPL_VARIANTS(WRAP_ATOMIC_OP_RET, atomic_and_fetch)
ATOMIC_IMPL_VARIANTS(WRAP_ATOMIC_OP_RET, atomic_or_fetch)
ATOMIC_IMPL_VARIANTS(WRAP_ATOMIC_OP_RET, atomic_add_fetch)
ATOMIC_IMPL_VARIANTS(WRAP_ATOMIC_OP_RET, atomic_exchange)
ATOMIC_IMPL_VARIANTS(WRAP_ATOMIC_OP_CAS, cas)

#undef ATOMIC_IMPL_VARIANTS
#undef ATOMIC_OP_VOID
#undef ATOMIC_OP_RET
#undef ATOMIC_OP_CAS
// preprocess on

//---------------------------------------------------------------------------
INTERFACE[arm && !arm_v6plus]:

#include "processor.h"

template<typename T> inline
T
atomic_load_acquire(T const *mem)
{ return atomic_load_relaxed(mem); }

template<typename T> inline
T
atomic_load_seq_cst(T const *mem)
{ return atomic_load_relaxed(mem); }

template<typename T, typename V> inline
void
atomic_store_release(T *mem, V value)
{ atomic_store_relaxed(mem, value); }

template<typename T, typename V> inline
void
atomic_store_seq_cst(T *mem, V value)
{ atomic_store_relaxed(mem, value); }

// preprocess off
// Fall-back UP implementations for armv5
#define ATOMIC_OP(name, op)                                                    \
  template<typename T, typename V>                                             \
  requires(sizeof(T) == 4) inline                                              \
  void                                                                         \
  atomic_##name##_relaxed(T *mem, V value)                                     \
  {                                                                            \
    static_assert(cxx::is_integral_v<T>);                                      \
    T val = value;                                                             \
    Proc::Status s = Proc::cli_save();                                         \
    *mem op##= val;                                                            \
    Proc::sti_restore(s);                                                      \
  }                                                                            \
                                                                               \
  template<typename T, typename V>                                             \
  requires(sizeof(T) == 4) inline                                              \
  T                                                                            \
  atomic_##name##_fetch##_relaxed(T *mem, V value)                             \
  {                                                                            \
    static_assert(cxx::is_integral_v<T>);                                      \
    T val = value;                                                             \
    Proc::Status s = Proc::cli_save();                                         \
    *mem op##= val;                                                            \
    T res = *mem;                                                              \
    Proc::sti_restore(s);                                                      \
    return res;                                                                \
  }                                                                            \
                                                                               \
  template<typename T, typename V>                                             \
  requires(sizeof(T) == 4) inline                                              \
  T                                                                            \
  atomic_fetch_##name##_relaxed(T *mem, V value)                               \
  {                                                                            \
    static_assert(cxx::is_integral_v<T>);                                      \
    Proc::Status s = Proc::cli_save();                                         \
    T res = *mem;                                                              \
    *mem op##= value;                                                          \
    Proc::sti_restore(s);                                                      \
    return res;                                                                \
  }
ATOMIC_OP(and, &)
ATOMIC_OP(or, |)
ATOMIC_OP(add, +)
#undef ATOMIC_OP

template<typename T, typename V>
requires(sizeof(T) == 4) inline
T
atomic_exchange_relaxed(T *mem, V value)
{
  T val = value;
  Proc::Status s = Proc::cli_save();
  T old = *mem;
  *mem = val;
  Proc::sti_restore(s);
  return old;
}

template<typename T>
requires(sizeof(T) == 4) inline
bool
cas_relaxed(T *mem, T oldval, T newval)
{
  Proc::Status s = Proc::cli_save();
  bool success = *mem == oldval;
  if (success)
    *mem = newval;
  Proc::sti_restore(s);
  return success;
}

#define WRAP_ATOMIC_OP_VOID(name, order)                                       \
  template<typename T, typename V>  inline                                     \
  void                                                                         \
  name##_##order(T *mem, V value)                                              \
  {                                                                            \
    name ## _relaxed(mem, value);                                              \
  }

#define WRAP_ATOMIC_OP_RET(name, order)                                        \
  template<typename T, typename V>  inline                                     \
  T                                                                            \
  name##_##order(T *mem, V value)                                              \
  {                                                                            \
    return name ## _relaxed(mem, value);                                       \
  }

#define WRAP_ATOMIC_OP_CAS(name, order)                                        \
  template<typename T> inline                                                  \
  bool                                                                         \
  name##_##order(T *mem, T oldval, T newval)                                   \
  {                                                                            \
    return name ## _relaxed(mem, oldval, newval);                              \
  }

#define ATOMIC_IMPL_VARIANTS(OP_MACRO, name)                                   \
  OP_MACRO(name, acquire)                                                      \
  OP_MACRO(name, release)                                                      \
  OP_MACRO(name, acq_rel)                                                      \
  OP_MACRO(name, seq_cst)

ATOMIC_IMPL_VARIANTS(WRAP_ATOMIC_OP_VOID, atomic_and)
ATOMIC_IMPL_VARIANTS(WRAP_ATOMIC_OP_VOID, atomic_or)
ATOMIC_IMPL_VARIANTS(WRAP_ATOMIC_OP_VOID, atomic_add)
ATOMIC_IMPL_VARIANTS(WRAP_ATOMIC_OP_RET, atomic_fetch_and)
ATOMIC_IMPL_VARIANTS(WRAP_ATOMIC_OP_RET, atomic_fetch_or)
ATOMIC_IMPL_VARIANTS(WRAP_ATOMIC_OP_RET, atomic_fetch_add)
ATOMIC_IMPL_VARIANTS(WRAP_ATOMIC_OP_RET, atomic_and_fetch)
ATOMIC_IMPL_VARIANTS(WRAP_ATOMIC_OP_RET, atomic_or_fetch)
ATOMIC_IMPL_VARIANTS(WRAP_ATOMIC_OP_RET, atomic_add_fetch)
ATOMIC_IMPL_VARIANTS(WRAP_ATOMIC_OP_RET, atomic_exchange)
ATOMIC_IMPL_VARIANTS(WRAP_ATOMIC_OP_CAS, cas)

#undef ATOMIC_IMPL_VARIANTS
#undef ATOMIC_OP_VOID
#undef ATOMIC_OP_RET
#undef ATOMIC_OP_CAS
// preprocess on
