INTERFACE [arm]:

#include "alternatives.h"

// preprocess off
#define ATOMIC_LX_SX_VARIANTS(OP_MACRO, ...)                                   \
  OP_MACRO(__VA_ARGS__ __VA_OPT__(,) _relaxed,  ,  ,         )                 \
  OP_MACRO(__VA_ARGS__ __VA_OPT__(,) _acquire, a,  , "memory")                 \
  OP_MACRO(__VA_ARGS__ __VA_OPT__(,) _release,  , l, "memory")                 \
  OP_MACRO(__VA_ARGS__ __VA_OPT__(,) _acq_rel, a, l, "memory")                 \
  OP_MACRO(__VA_ARGS__ __VA_OPT__(,) _seq_cst, a, l, "memory")


#define ATOMIC_LX_SX_OP_(name, op, size, pfx, order_name, ol, os, cl)          \
  template<typename T, typename V>                                             \
  requires(sizeof(T) == size) inline                                           \
  void                                                                         \
  _lx_sx_atomic_##name##order_name(T *mem, V value)                            \
  {                                                                            \
    static_assert(cxx::is_integral_v<T>);                                      \
    T val = value;                                                             \
    T res;                                                                     \
    Mword tmp;                                                                 \
                                                                               \
    asm volatile (                                                             \
        "     prfm  pstl1strm, %[mem] \n"                                      \
        "1:   ld"#ol"xr  %"#pfx"[res], %[mem] \n"                              \
        "   " #op " %"#pfx"[res], %"#pfx"[res], %"#pfx"[val] \n"               \
        "     st"#os"xr  %w[tmp], %"#pfx"[res], %[mem] \n"                     \
        "     cbnz  %w[tmp], 1b \n"                                            \
        : [res] "=&r" (res), [tmp] "=&r" (tmp), [mem] "+Q" (*mem)              \
        : [val] "r" (val)                                                      \
        : cl);                                                                 \
  }                                                                            \
                                                                               \
  template<typename T, typename V>                                             \
  requires(sizeof(T) == size) inline                                           \
  T                                                                            \
  _lx_sx_atomic_fetch_##name##order_name(T *mem, V value)                      \
  {                                                                            \
    static_assert(cxx::is_integral_v<T>);                                      \
    T val = value;                                                             \
    T res, old;                                                                \
    Mword tmp;                                                                 \
                                                                               \
    asm volatile (                                                             \
        "     prfm  pstl1strm, %[mem] \n"                                      \
        "1:   ld"#ol"xr  %"#pfx"[old], %[mem] \n"                              \
        "   " #op " %"#pfx"[res], %"#pfx"[old], %"#pfx"[val] \n"               \
        "     st"#os"xr  %w[tmp], %"#pfx"[res], %[mem] \n"                     \
        "     cbnz  %w[tmp], 1b \n"                                            \
        : [res] "=&r" (res), [old] "=&r" (old), [tmp] "=&r" (tmp),             \
          [mem] "+Q" (*mem)                                                    \
        : [val] "r" (val)                                                      \
        : cl);                                                                 \
    return old;                                                                \
  }                                                                            \
                                                                               \
  template<typename T, typename V>                                             \
  requires(sizeof(T) == size) inline                                           \
  T                                                                            \
  _lx_sx_atomic_##name##_fetch##order_name(T *mem, V value)                    \
  {                                                                            \
    static_assert(cxx::is_integral_v<T>);                                      \
    T val = value;                                                             \
    T res;                                                                     \
    Mword tmp;                                                                 \
                                                                               \
    asm volatile (                                                             \
        "     prfm  pstl1strm, %[mem] \n"                                      \
        "1:   ld"#ol"xr  %"#pfx"[res], %[mem] \n"                              \
        "   " #op " %"#pfx"[res], %"#pfx"[res], %"#pfx"[val] \n"               \
        "     st"#os"xr  %w[tmp], %"#pfx"[res], %[mem] \n"                     \
        "     cbnz  %w[tmp], 1b \n"                                            \
        : [res] "=&r" (res), [tmp] "=&r" (tmp), [mem] "+Q" (*mem)              \
        : [val] "r" (val)                                                      \
        : cl);                                                                 \
    return res;                                                                \
  }
#define ATOMIC_LX_SX_OP(name, op)                                              \
  ATOMIC_LX_SX_VARIANTS(ATOMIC_LX_SX_OP_, name, op, 4, w)                      \
  ATOMIC_LX_SX_VARIANTS(ATOMIC_LX_SX_OP_, name, op, 8, x)

ATOMIC_LX_SX_OP(and, and)
ATOMIC_LX_SX_OP(or, orr)
ATOMIC_LX_SX_OP(add, add)
#undef ATOMIC_LX_SX_OP_
#undef ATOMIC_LX_SX_OP


#define ATOMIC_LX_SX_EXCHANGE(size, pfx, order_name, ol, os, cl)               \
  template<typename T, typename V>                                             \
  requires(sizeof(T) == size) inline                                           \
  T                                                                            \
  _lx_sx_atomic_exchange##order_name(T *mem, V value)                          \
  {                                                                            \
    T val = value;                                                             \
    T res;                                                                     \
    Mword tmp;                                                                 \
                                                                               \
    asm volatile (                                                             \
        "     prfm  pstl1strm, %[mem] \n"                                      \
        "1:   ld"#ol"xr  %"#pfx"[res], %[mem] \n"                              \
        "     st"#os"xr  %w[tmp], %"#pfx"[val], %[mem] \n"                     \
        "     cbnz  %w[tmp], 1b \n"                                            \
        : [res] "=&r" (res), [tmp] "=&r" (tmp), [mem] "+Q" (*mem)              \
        : [val] "r" (val)                                                      \
        : cl);                                                                 \
    return res;                                                                \
  }
ATOMIC_LX_SX_VARIANTS(ATOMIC_LX_SX_EXCHANGE, 4, w)
ATOMIC_LX_SX_VARIANTS(ATOMIC_LX_SX_EXCHANGE, 8, x)
#undef ATOMIC_LX_SX_EXCHANGE


#define ATOMIC_LX_SX_CAS(size,pfx, order_name, ol, os, /*cl*/...)              \
  template<typename T>                                                         \
  requires(sizeof(T) == size) inline                                           \
  bool                                                                         \
  _lx_sx_cas##order_name(T *mem, T oldval, T newval)                           \
  {                                                                            \
    T tmp;                                                                     \
    Mword res;                                                                 \
                                                                               \
    asm volatile                                                               \
      ("mov     %[res], #1 \n"                                                 \
       "prfm    pstl1strm, %[mem] \n"                                          \
       "1: \n"                                                                 \
       "ld"#ol"xr    %"#pfx"[tmp], %[mem] \n"                                  \
       "cmp     %"#pfx"[tmp], %"#pfx"[oldval] \n"                              \
       "b.ne    2f \n"                                                         \
       "st"#os"xr   %w[res], %"#pfx"[newval], %[mem] \n"                       \
       "cbnz    %w[res], 1b \n"                                                \
       "2: \n"                                                                 \
       : [tmp] "=&r" (tmp), [res] "=&r" (res), [mem] "+Q" (*mem)               \
       : [newval] "r" (newval), [oldval] "r" (oldval)                          \
       : "cc" __VA_OPT__(,) __VA_ARGS__);                                      \
                                                                               \
    /* res == 0 is ok */                                                       \
    /* res == 1 is failed */                                                   \
                                                                               \
    return !res;                                                               \
  }
ATOMIC_LX_SX_VARIANTS(ATOMIC_LX_SX_CAS, 4, w)
ATOMIC_LX_SX_VARIANTS(ATOMIC_LX_SX_CAS, 8, x)
#undef ATOMIC_LX_SX_CAS
#undef ATOMIC_LX_SX_VARIANTS


#define ATOMIC_LSE_VARIANTS(OP_MACRO, ...)                                     \
  OP_MACRO(__VA_ARGS__ __VA_OPT__(,) _relaxed,   ,         )                   \
  OP_MACRO(__VA_ARGS__ __VA_OPT__(,) _acquire, a , "memory")                   \
  OP_MACRO(__VA_ARGS__ __VA_OPT__(,) _release, l , "memory")                   \
  OP_MACRO(__VA_ARGS__ __VA_OPT__(,) _acq_rel, al, "memory")                   \
  OP_MACRO(__VA_ARGS__ __VA_OPT__(,) _seq_cst, al, "memory")

#define ATOMIC_LSE_OP_(name, op, rop, neg, size, pfx, order_name, order, cl)   \
  template<typename T, typename V>                                             \
  requires(sizeof(T) == size) inline                                           \
  void                                                                         \
  _lse_atomic_##name##order_name(T *mem, V value)                              \
  {                                                                            \
    static_assert(cxx::is_integral_v<T>);                                      \
    T val = value;                                                             \
    T old;                                                                     \
                                                                               \
    /* We must not use wzr/xzr as destination register, */                     \
    /* as that would drop acquire semantics. */                                \
    asm volatile (                                                             \
        ".arch_extension lse \n"                                               \
        "ld"#op #order " %"#pfx"[val], %"#pfx"[old], %[mem] \n"                \
        : [old] "=r" (old), [mem] "+Q" (*mem)                                  \
        : [val] "r" (neg val)                                                  \
        : cl);                                                                 \
  }                                                                            \
                                                                               \
  template<typename T, typename V>                                             \
  requires(sizeof(T) == size) inline                                           \
  T                                                                            \
  _lse_atomic_fetch_##name##order_name(T *mem, V value)                        \
  {                                                                            \
    static_assert(cxx::is_integral_v<T>);                                      \
    T val = value;                                                             \
    T old;                                                                     \
                                                                               \
    asm volatile (                                                             \
        ".arch_extension lse \n"                                               \
        "ld"#op #order " %"#pfx"[val], %"#pfx"[old], %[mem] \n"                \
        : [old] "=r" (old), [mem] "+Q" (*mem)                                  \
        : [val] "r" (neg val)                                                  \
        : cl);                                                                 \
    return old;                                                                \
  }                                                                            \
                                                                               \
  template<typename T, typename V>                                             \
  requires(sizeof(T) == size) inline                                           \
  T                                                                            \
  _lse_atomic_##name##_fetch##order_name(T *mem, V value)                      \
  {                                                                            \
    static_assert(cxx::is_integral_v<T>);                                      \
    T val = value;                                                             \
    T res;                                                                     \
                                                                               \
    asm volatile (                                                             \
        ".arch_extension lse \n"                                               \
        "ld"#op #order " %"#pfx"[val], %"#pfx"[res], %[mem] \n"                \
        : [res] "=r" (res), [mem] "+Q" (*mem)                                  \
        : [val] "r" (neg val)                                                  \
        : cl);                                                                 \
    return res rop val;                                                        \
  }
#define ATOMIC_LSE_OP(name, op, rop, neg)                                      \
  ATOMIC_LSE_VARIANTS(ATOMIC_LSE_OP_, name, op, rop, neg, 4, w)                \
  ATOMIC_LSE_VARIANTS(ATOMIC_LSE_OP_, name, op, rop, neg, 8, x)

// There is no ldand instruction, thus we have to negate the value and use ldclr.
ATOMIC_LSE_OP(and, clr, &, ~)
ATOMIC_LSE_OP(or, set, |, )
ATOMIC_LSE_OP(add, add, +, )
#undef ATOMIC_LSE_OP_
#undef ATOMIC_LSE_OP


#define ATOMIC_LSE_EXCHANGE(size, pfx, order_name, order, cl)                  \
  template<typename T, typename V>                                             \
  requires(sizeof(T) == size) inline                                           \
  T                                                                            \
  _lse_atomic_exchange##order_name(T *mem, V value)                            \
  {                                                                            \
    T val = value;                                                             \
    T old;                                                                     \
                                                                               \
    asm volatile (                                                             \
        ".arch_extension lse \n"                                               \
        "swp" #order " %"#pfx"[val], %"#pfx"[old], %[mem] \n"                  \
        : [old] "=r" (old), [mem] "+Q" (*mem)                                  \
        : [val] "r" (val)                                                      \
        : cl);                                                                 \
    return old;                                                                \
  }
ATOMIC_LSE_VARIANTS(ATOMIC_LSE_EXCHANGE, 4, w)
ATOMIC_LSE_VARIANTS(ATOMIC_LSE_EXCHANGE, 8, x)
#undef ATOMIC_LSE_EXCHANGE


#define ATOMIC_LSE_CAS(size, pfx, order_name, order, cl)                       \
  template<typename T>                                                         \
  requires(sizeof(T) == size) inline                                           \
  bool                                                                         \
  _lse_cas##order_name(T *mem, T oldval, T newval)                             \
  {                                                                            \
    T old = oldval;                                                            \
    asm volatile (                                                             \
        ".arch_extension lse \n"                                               \
        "cas"#order " %"#pfx"[old], %"#pfx"[newval], %[mem] \n"                \
        : [old] "+r" (old), [mem] "+Q" (*mem)                                  \
        : [newval] "r" (newval)                                                \
        : cl);                                                                 \
                                                                               \
    return old == oldval;                                                      \
  }
ATOMIC_LSE_VARIANTS(ATOMIC_LSE_CAS, 4, w)
ATOMIC_LSE_VARIANTS(ATOMIC_LSE_CAS, 8, x)
#undef ATOMIC_LSE_CAS
#undef ATOMIC_LSE_VARIANTS


#define ATOMIC_LOAD_OP_(size, pfx, order_name, order, cst, cl)                 \
  template<typename T> requires(sizeof(T) == size) inline                      \
  T                                                                            \
  atomic_load##order_name(T const *mem)                                        \
  {                                                                            \
    T res;                                                                     \
    asm volatile (                                                             \
        "ld"#order"r %"#pfx"[res], %[mem]"                                     \
        : [res] "=r" (res)                                                     \
        : [mem] cst (*mem)                                                     \
        : cl);                                                                 \
    return res;                                                                \
  }

#define ATOMIC_LOAD_OP(order_name, order, cst, cl)                             \
  ATOMIC_LOAD_OP_(4, w, order_name, order, cst, cl)                            \
  ATOMIC_LOAD_OP_(8, x, order_name, order, cst, cl)
ATOMIC_LOAD_OP(_relaxed,  , "m",         )
ATOMIC_LOAD_OP(_acquire, a, "Q", "memory")
ATOMIC_LOAD_OP(_seq_cst, a, "Q", "memory")
#undef ATOMIC_LOAD_OP_
#undef ATOMIC_LOAD_OP


#define ATOMIC_STORE_OP_(size, pfx, order_name, order, cst, cl)                \
  template<typename T, typename V> requires(sizeof(T) == size) inline          \
  void                                                                         \
  atomic_store##order_name(T *mem, V value)                                    \
  {                                                                            \
    T val = value;                                                             \
    asm volatile (                                                             \
        "st"#order"r %"#pfx"[val], %[mem]"                                     \
        : [mem] cst (*mem)                                                     \
        : [val] "r" (val)                                                      \
        : cl);                                                                 \
  }

#define ATOMIC_STORE_OP(order_name, order, cst, cl)                            \
  ATOMIC_STORE_OP_(4, w, order_name, order, cst, cl)                           \
  ATOMIC_STORE_OP_(8, x, order_name, order, cst, cl)
ATOMIC_STORE_OP(_relaxed,  , "=m",         )
ATOMIC_STORE_OP(_release, l, "=Q", "memory")
ATOMIC_STORE_OP(_seq_cst, l, "=Q", "memory")
#undef ATOMIC_STORE_OP_
#undef ATOMIC_STORE_OP


struct _boot_cpu_has_lse : public Alternative_static_functor<_boot_cpu_has_lse>
{
  static bool probe()
  {
    Mword isar0;
    asm ("mrs %0, ID_AA64ISAR0_EL1": "=r" (isar0));
    return ((isar0 >> 20) & 0xf) >= 0b10;
  }
};

#define ATOMIC_IMPL_VARIANTS(OP_MACRO, name, ...)                              \
  OP_MACRO(name ## _relaxed __VA_OPT__(,) __VA_ARGS__)                         \
  OP_MACRO(name ## _acquire __VA_OPT__(,) __VA_ARGS__)                         \
  OP_MACRO(name ## _release __VA_OPT__(,) __VA_ARGS__)                         \
  OP_MACRO(name ## _acq_rel __VA_OPT__(,) __VA_ARGS__)                         \
  OP_MACRO(name ## _seq_cst __VA_OPT__(,) __VA_ARGS__)

#define ATOMIC_IMPL_(name, ret)                                                \
  template<typename T, typename V> inline                                      \
  ret                                                                          \
  name(T *mem, V value)                                                        \
  {                                                                            \
    if constexpr(TAG_ENABLED(arm_lse))                                         \
      return _lse_##name(mem, value);                                          \
    else if constexpr(TAG_ENABLED(arm_lse_may))                                \
      return _boot_cpu_has_lse() ? _lse_##name(mem, value)                     \
                                 : _lx_sx_##name(mem, value);                  \
    else                                                                       \
      return _lx_sx_##name(mem, value);                                        \
  }

#define ATOMIC_IMPL(ret, name)                                                 \
  ATOMIC_IMPL_VARIANTS(ATOMIC_IMPL_, name, ret)

ATOMIC_IMPL(void, atomic_and)
ATOMIC_IMPL(void, atomic_or)
ATOMIC_IMPL(void, atomic_add)
ATOMIC_IMPL(T, atomic_fetch_and)
ATOMIC_IMPL(T, atomic_fetch_or)
ATOMIC_IMPL(T, atomic_fetch_add)
ATOMIC_IMPL(T, atomic_and_fetch)
ATOMIC_IMPL(T, atomic_or_fetch)
ATOMIC_IMPL(T, atomic_add_fetch)
ATOMIC_IMPL(T, atomic_exchange)
#undef ATOMIC_IMPL

#define ATOMIC_IMPL_CAS(name)                                                  \
  template<typename T> inline                                                  \
  bool                                                                         \
  name(T *mem, T oldval, T newval)                                             \
  {                                                                            \
    if constexpr (TAG_ENABLED(arm_lse))                                        \
      return _lse_##name(mem, oldval, newval);                                 \
    else if constexpr(TAG_ENABLED(arm_lse_may))                                \
      return _boot_cpu_has_lse() ? _lse_##name(mem, oldval, newval)            \
                                 : _lx_sx_##name(mem, oldval, newval);         \
    else                                                                       \
      return _lx_sx_##name(mem, oldval, newval);                               \
  }
ATOMIC_IMPL_VARIANTS(ATOMIC_IMPL_CAS, cas)
#undef ATOMIC_IMPL_CAS
#undef ATOMIC_IMPL_VARIANTS
// preprocess on
