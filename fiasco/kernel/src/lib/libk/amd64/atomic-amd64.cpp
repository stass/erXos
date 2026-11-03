INTERFACE [amd64]:

// preprocess off
#define ATOMIC_VARIANTS(OP_MACRO, ...)                                         \
  OP_MACRO(__VA_ARGS__ __VA_OPT__(,) _relaxed,         )                       \
  OP_MACRO(__VA_ARGS__ __VA_OPT__(,) _acquire, "memory")                       \
  OP_MACRO(__VA_ARGS__ __VA_OPT__(,) _release, "memory")                       \
  OP_MACRO(__VA_ARGS__ __VA_OPT__(,) _acq_rel, "memory")                       \
  OP_MACRO(__VA_ARGS__ __VA_OPT__(,) _seq_cst, "memory")


#define ATOMIC_OP_(op, size, suffix, order_name, cl)                           \
  template<typename T, typename V>                                             \
  requires(sizeof(T) == size) inline                                           \
  void                                                                         \
  atomic_##op##order_name(T *mem, V value)                                     \
  {                                                                            \
    static_assert(cxx::is_integral_v<T>);                                      \
    T val = value;                                                             \
    asm volatile (                                                             \
      "lock; "#op #suffix" %1, %2"                                             \
      : "=m"(*mem)                                                             \
      : "er"(val), "m"(*mem)                                                   \
      : cl);                                                                   \
  }

#define ATOMIC_OP(op)                                                          \
  ATOMIC_VARIANTS(ATOMIC_OP_, op, 4, l)                                        \
  ATOMIC_VARIANTS(ATOMIC_OP_, op, 8, q)

ATOMIC_OP(or)
ATOMIC_OP(and)
ATOMIC_OP(add)
#undef ATOMIC_OP_
#undef ATOMIC_OP


#define ATOMIC_CAS_OP(order_name, cl)                                          \
  template<typename T> requires(sizeof(T) == 4 || sizeof(T) == 8) inline       \
  bool                                                                         \
  cas##order_name(T *mem, T cmpval, T newval)                                  \
  {                                                                            \
    T oldval_ignore;                                                           \
    Mword zflag;                                                               \
    asm volatile ("lock; cmpxchg %[newval], %[mem]"                            \
                  : "=a"(oldval_ignore), "=@ccz"(zflag)                        \
                  : [newval]"r"(newval), [mem]"m"(*mem), "a"(cmpval)           \
                  : cl);                                                       \
    return zflag;                                                              \
  }
ATOMIC_VARIANTS(ATOMIC_CAS_OP)
#undef ATOMIC_CAS_OP


#define ATOMIC_OP(op, cop, order_name, cl)                                     \
  template<typename T, typename V> inline                                      \
  T                                                                            \
  atomic_fetch_##op##order_name(T *mem, V value)                               \
  {                                                                            \
    static_assert(cxx::is_integral_v<T>);                                      \
    T val = value;                                                             \
    T old;                                                                     \
    do                                                                         \
      {                                                                        \
        old = *mem;                                                            \
      }                                                                        \
    while (!cas##order_name(mem, old, old cop val));                           \
    return old;                                                                \
  }                                                                            \
                                                                               \
  template<typename T, typename V> inline                                      \
  T                                                                            \
  atomic_##op##_fetch##order_name(T *mem, V value)                             \
  {                                                                            \
    static_assert(cxx::is_integral_v<T>);                                      \
    T val = value;                                                             \
    T old;                                                                     \
    do                                                                         \
      {                                                                        \
        old = *mem;                                                            \
      }                                                                        \
    while (!cas##order_name(mem, old, old cop val));                           \
    return old cop val;                                                        \
  }
ATOMIC_VARIANTS(ATOMIC_OP, and, &)
ATOMIC_VARIANTS(ATOMIC_OP, or, |)
#undef ATOMIC_OP


#define ATOMIC_ADD_OP(order_name, cl)                                          \
  template<typename T, typename V>                                             \
  requires(sizeof(T) == 4 || sizeof(T) == 8) inline                            \
  T                                                                            \
  atomic_fetch_add##order_name(T *mem, V value)                                \
  {                                                                            \
    static_assert(cxx::is_integral_v<T>);                                      \
    T val = value;                                                             \
    T old;                                                                     \
    asm volatile ("lock; xadd %1, %0"                                          \
                  : "+m"(*mem), "=r"(old)                                      \
                  : "1"(val)                                                   \
                  : cl);                                                       \
    return old;                                                                \
  }                                                                            \
                                                                               \
  template<typename T, typename V>                                             \
  requires(sizeof(T) == 4 || sizeof(T) == 8) inline                            \
  T                                                                            \
  atomic_add_fetch##order_name(T *mem, V value)                                \
  {                                                                            \
    static_assert(cxx::is_integral_v<T>);                                      \
    T val = value;                                                             \
    T old;                                                                     \
    asm volatile ("lock; xadd %1, %0"                                          \
                  : "+m"(*mem), "=r"(old)                                      \
                  : "1"(val)                                                   \
                  : cl);                                                       \
    return old + val;                                                          \
  }
ATOMIC_VARIANTS(ATOMIC_ADD_OP)
#undef ATOMIC_ADD_OP


#define ATOMIC_EXCHANGE_OP(order_name, cl)                                     \
  template<typename T, typename V> inline                                      \
  T                                                                            \
  atomic_exchange##order_name(T *mem, V value)                                 \
  {                                                                            \
    static_assert(sizeof(T) == 4 || sizeof(T) == 8);                           \
    T val = value;                                                             \
                                                                               \
    /* processor locking even without explicit LOCK prefix */                  \
    asm volatile ("xchg %[val], %[mem]\n"                                      \
                  : [val] "=r"(val), [mem] "+m"(*mem)                          \
                  : "0"(val)                                                   \
                  : cl);                                                       \
                                                                               \
    return val;                                                                \
  }
ATOMIC_VARIANTS(ATOMIC_EXCHANGE_OP)
#undef ATOMIC_EXCHANGE_OP


template<typename T> requires(sizeof(T) == 4) inline
T
atomic_load_relaxed(T const *mem)
{
  T res;
  asm volatile ("movl %[mem], %[res]"
                : [res] "=r"(res)
                : [mem] "m"(*mem));
  return res;
}

template<typename T> requires(sizeof(T) == 8) inline
T
atomic_load_relaxed(T const *mem)
{
  T res;
  asm volatile ("movq %[mem], %[res]"
                : [res] "=r"(res)
                : [mem] "m"(*mem));
  return res;
}

template<typename T> requires(sizeof(T) == 4) inline
T
atomic_load_seq_cst(T const *mem)
{
  T res;
  asm volatile ("movl %[mem], %[res]"
                : [res] "=r"(res)
                : [mem] "m"(*mem)
                : "memory");
  return res;
}

template<typename T> requires(sizeof(T) == 8) inline
T
atomic_load_seq_cst(T const *mem)
{
  T res;
  asm volatile ("movq %[mem], %[res]"
                : [res] "=r"(res)
                : [mem] "m"(*mem)
                : "memory");
  return res;
}

template<typename T> inline
T
atomic_load_acquire(T const *mem)
{
  return atomic_load_seq_cst(mem);
}


template<typename T, typename V> requires(sizeof(T) == 4) inline
void
atomic_store_relaxed(T *mem, V value)
{
  T val = value;
  asm volatile ("movl %[val], %[mem]"
                : [mem] "=m"(*mem)
                : [val] "ir"(val));
}

template<typename T, typename V> requires(sizeof(T) == 8) inline
void
atomic_store_relaxed(T *mem, V value)
{
  T val = value;
  asm volatile ("movq %[val], %[mem]"
                : [mem] "=m"(*mem)
                : [val] "r"(val));
}


template<typename T, typename V> requires(sizeof(T) == 4) inline
void
atomic_store_release(T *mem, V value)
{
  T val = value;
  asm volatile ("movl %[val], %[mem]"
                : [mem] "=m"(*mem)
                : [val] "ir"(val)
                : "memory");
}

template<typename T, typename V> requires(sizeof(T) == 8) inline
void
atomic_store_release(T *mem, V value)
{
  T val = value;
  asm volatile ("movq %[val], %[mem]"
                : [mem] "=m"(*mem)
                : [val] "r"(val)
                : "memory");
}

template<typename T, typename V> inline
void
atomic_store_seq_cst(T *mem, V value)
{
  atomic_exchange_seq_cst(mem, value);
}
// preprocess on

//----------------------------------------------------------------------------
IMPLEMENTATION [amd64]:

inline
void
local_atomic_add(Mword *mem, Mword value)
{
  asm volatile ("addq %1, %2" : "=m"(*mem) : "er"(value), "m"(*mem) : "memory");
}

inline
void
local_atomic_and(Mword *mem, Mword value)
{
  asm volatile ("andq %1, %2" : "=m"(*mem) : "er"(value), "m"(*mem) : "memory");
}

inline
void
local_atomic_or(Mword *mem, Mword value)
{
  asm volatile ("orq %1, %2" : "=m"(*mem) : "er"(value), "m"(*mem) : "memory");
}

template<typename T> inline
bool
local_cas(T *mem, T oldval, T newval)
{
  static_assert(sizeof(T) == sizeof(Mword));

  Mword oldval_ignore, zflag;

  asm volatile ("cmpxchgq %[newval], %[mem]"
                : "=a"(oldval_ignore), "=@ccz"(zflag)
                : [newval]"r"(newval), [mem]"m"(*mem), "a"(oldval)
                : "memory");

  return zflag;
}
