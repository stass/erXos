INTERFACE:

#include "types.h"

void
local_atomic_and(Mword *mem, Mword value);

void
local_atomic_or(Mword *mem, Mword value);

void
local_atomic_add(Mword *mem, Mword value);

//---------------------------------------------------------------------------
IMPLEMENTATION:

/**
 * Atomically test and modify memory \c without protection against concurrent
 * writes from other CPUs (\c not SMP-safe). The memory is only written if it
 * contains a dedicated value. For the variant with protection against
 * concurrent writes from other CPUs, \see cas().
 *
 * \param mem     Pointer to the memory to change.
 * \param oldval  Only write 'newval' if the memory contains this value.
 * \param newval  Write this value if the memory contains 'oldval'.
 * \return True if the memory was written, false otherwise.
 */
template< typename Type >
bool
local_cas(Type *mem, Type oldval, Type newval);

/**
 * Atomically change certain bits of memory \c without protection against
 * concurrent writes from other CPUs (\c not SMP-safe).
 *
 * \param ptr   Pointer to the memory to change.
 * \param mask  Mask to apply before changing the memory.
 * \param bits  Bits to apply by logical OR to the memory.
 */
template <typename T> inline
T
local_atomic_change(T *ptr, T mask, T bits)
{
  T old;
  do
    {
      old = *ptr;
    }
  while (!local_cas(ptr, old, (old & mask) | bits));
  return old;
}

/**
 * Atomically load a value from the given memory location.
 *
 * Performs the load operation using sequentially consistent memory order,
 * providing the strongest possible guarantees as a safe default choice.
 *
 * If required, use one of the variants that explicitly specify the
 * memory order: relaxed, consume, acquire, or seq_cst
 *
 * \note The difference between an atomic_load_acquire and an
 *       atomic_load_seq_cst is quite subtle. They both provide the same
 *       visibility guarantees, but the atomic_load_seq_cst in addition provides
 *       the global ordering constraint with other sequentially consistent
 *       atomic operations (does not affect regular non-atomic memory accesses).
 *
 * \param mem  Pointer to the memory location to operate on.
 * \return     The atomically read value.
 */
template<typename T> inline
T
atomic_load(T const *mem)
{ return atomic_load_seq_cst<T>(mem); }

/**
 * Atomically load a pointer value that then carries a data-dependency.
 *
 * \param  mem  Pointer to the memory to load the pointer from.
 *
 * \note Must be only used with pointers, integers are just to prone for
 *       incorrect-optimizations by the compiler.
 *       However, bit twiddling is allowed, by casting to unintptr_t and back,
 *       but bits must be preserved (see rcu document in Linux).
 */
template<typename T> inline
T
atomic_load_consume(T const *mem)
{
    static_assert(cxx::is_pointer_v<T>, "Must be pointer.");
    static_assert(sizeof(T) == sizeof(void *), "Must be regular pointer-sized.");
    // All hardware implementations (apart from the DEC Alpha) respect
    // data-dependencies. The tricky thing is to prevent the compiler from
    // transforming the code in a way that replaces the data-depenceny with a
    // control-dependency, since the latter is not honored by hardware.
    // The compiler is prone to do such optimizations, if it has too much
    // information about potential pointer values (translation-unit local
    // variable, LTO, profile-driven optimization).
    //
    // NOTE: A test case ensures that the compiler cannot destroy our "volatile" workaround.
    return *static_cast<T const volatile *>(mem);
}

/**
 * Atomically store a value to the given memory location.
 *
 * Performs the store operation using sequentially consistent memory order,
 * providing the strongest possible guarantees as a safe default choice.
 *
 * If required, use one of the variants that explicitly specify the
 * memory order: relaxed, release, or seq_cst
 *
 * \param mem    Pointer to the memory location to operate on.
 * \param value  The value to store.
 */
template<typename T, typename V> inline
void
atomic_store(T *mem, V value)
{ atomic_store_seq_cst<T, V>(mem, value); }

/**
 * Atomically bitwise "and" a value to the given memory location.
 *
 * Performs the operation using sequentially consistent memory order,
 * providing the strongest possible guarantees as a safe default choice.
 *
 * If required, use one of the variants that explicitly specify the
 * memory order: relaxed, acquire, release, acq_rel or seq_cst
 *
 * \note The difference between an atomic_store_release and an
 *       atomic_store_seq_cst is quite subtle. They both provide the same
 *       visibility guarantees, but the atomic_store_seq_cst in addition provides
 *       the global ordering constraint with other sequentially consistent
 *       atomic operations (does not affect regular non-atomic memory accesses).
 *
 * \param mem    Pointer to the memory location to operate on.
 * \param value  The value to bitwise "and".
 */
template<typename T, typename V> inline
void
atomic_and(T *mem, V value)
{ return atomic_and_seq_cst(mem, value); }

/**
 * Atomically bitwise "or" a value to the given memory location.
 *
 * Performs the operation using sequentially consistent memory order,
 * providing the strongest possible guarantees as a safe default choice.
 *
 * If required, use one of the variants that explicitly specify the
 * memory order: relaxed, acquire, release, acq_rel or seq_cst
 *
 * \param mem    Pointer to the memory location to operate on.
 * \param value  The value to bitwise "or".
 */
template<typename T, typename V> inline
void
atomic_or(T *mem, V value)
{ return atomic_or_seq_cst(mem, value); }

/**
 * Atomically "add" a value to the given memory location.
 *
 * Performs the operation using sequentially consistent memory order,
 * providing the strongest possible guarantees as a safe default choice.
 *
 * If required, use one of the variants that explicitly specify the
 * memory order: relaxed, acquire, release, acq_rel or seq_cst
 *
 * \param mem    Pointer to the memory location to operate on.
 * \param value  The value to "add".
 */
template<typename T, typename V> inline
void
atomic_add(T *mem, V value)
{ return atomic_add_seq_cst(mem, value); }

/**
 * Atomically bitwise "and" a value to the given memory location and return the
 * original value stored at that location.
 *
 * Performs the operation using sequentially consistent memory order,
 * providing the strongest possible guarantees as a safe default choice.
 *
 * If required, use one of the variants that explicitly specify the
 * memory order: relaxed, acquire, release, acq_rel or seq_cst
 *
 * \param mem    Pointer to the memory location to operate on.
 * \param value  The value to "and".
 * \return       The original value stored at the memory location.
 */
template<typename T, typename V> inline
T
atomic_fetch_and(T *mem, V value)
{ return atomic_fetch_and_seq_cst(mem, value); }

/**
 * Atomically bitwise "or" a value to the given memory location and return the
 * original value stored at that location.
 *
 * Performs the operation using sequentially consistent memory order,
 * providing the strongest possible guarantees as a safe default choice.
 *
 * If required, use one of the variants that explicitly specify the
 * memory order: relaxed, acquire, release, acq_rel or seq_cst
 *
 * \param mem    Pointer to the memory location to operate on.
 * \param value  The value to "or".
 * \return       The original value stored at the memory location.
 */
template<typename T, typename V> inline
T
atomic_fetch_or(T *mem, V value)
{ return atomic_fetch_or_seq_cst(mem, value); }

/**
 * Atomically "add" a value to the given memory location and return the
 * original value stored at that location.
 *
 * Performs the operation using sequentially consistent memory order,
 * providing the strongest possible guarantees as a safe default choice.
 *
 * If required, use one of the variants that explicitly specify the
 * memory order: relaxed, acquire, release, acq_rel or seq_cst
 *
 * \param mem    Pointer to the memory location to operate on.
 * \param value  The value to "add".
 * \return       The original value stored at the memory location.
 */
template<typename T, typename V> inline
T
atomic_fetch_add(T *mem, V value)
{ return atomic_fetch_add_seq_cst(mem, value); }

/**
 * Atomically bitwise "and" a value to the given memory location and return the
 * resulting value.
 *
 * Performs the operation using sequentially consistent memory order,
 * providing the strongest possible guarantees as a safe default choice.
 *
 * If required, use one of the variants that explicitly specify the
 * memory order: relaxed, acquire, release, acq_rel or seq_cst
 *
 * \param mem    Pointer to the memory location to operate on.
 * \param value  The value to "and".
 * \return       The resulting value.
 */
template<typename T, typename V> inline
T
atomic_and_fetch(T *mem, V value)
{ return atomic_and_fetch_seq_cst(mem, value); }

/**
 * Atomically bitwise "or" a value to the given memory location and return the
 * resulting value.
 *
 * Performs the operation using sequentially consistent memory order,
 * providing the strongest possible guarantees as a safe default choice.
 *
 * If required, use one of the variants that explicitly specify the
 * memory order: relaxed, acquire, release, acq_rel or seq_cst
 *
 * \param mem    Pointer to the memory location to operate on.
 * \param value  The value to "or".
 * \return       The resulting value.
 */
template<typename T, typename V> inline
T
atomic_or_fetch(T *mem, V value)
{ return atomic_or_fetch_seq_cst(mem, value); }

/**
 * Atomically "add" a value to the given memory location and return the
 * resulting value.
 *
 * Performs the operation using sequentially consistent memory order,
 * providing the strongest possible guarantees as a safe default choice.
 *
 * If required, use one of the variants that explicitly specify the
 * memory order: relaxed, acquire, release, acq_rel or seq_cst
 *
 * \param mem    Pointer to the memory location to operate on.
 * \param value  The value to "add".
 * \return       The resulting value.
 */
template<typename T, typename V> inline
T
atomic_add_fetch(T *mem, V value)
{ return atomic_add_fetch_seq_cst(mem, value); }

/**
 * Atomically exchange the value stored at given memory location with a given
 * value and return the original value stored at the location.
 *
 * Performs the operation using sequentially consistent memory order,
 * providing the strongest possible guarantees as a safe default choice.
 *
 * If required, use one of the variants that explicitly specify the
 * memory order: relaxed, acquire, release, acq_rel or seq_cst
 *
 * \param mem    Pointer to the memory location to operate on.
 * \param value  The new value to store.
 * \return       The original value.
 */
template<typename T, typename V> inline
T
atomic_exchange(T *mem, V value)
{ return atomic_exchange_seq_cst(mem, value); }

//---------------------------------------------------------------------------
IMPLEMENTATION [!mp]:

/**
 * Atomically test and modify memory with protection against concurrent writes
 * from other CPUs (SMP-safe). On UP systems, this function is equivalent to
 * \see 'local_cas'.
 *
 * \param mem     Pointer to the memory to change.
 * \param oldval  Only write 'newval' if the memory contains this value.
 * \param newval  Write this value if the memory contains 'oldval'.
 * \return True if the memory was written, false otherwise.
 */
template< typename T > inline
bool
cas(T *mem, T oldval, T newval)
{ return local_cas(mem, oldval, newval); }

//---------------------------------------------------------------------------
IMPLEMENTATION [mp]:

/**
 * Atomically test and modify memory with protection against concurrent writes
 * from other CPUs (SMP-safe).
 *
 * Performs the operation using sequentially consistent memory order on success,
 * providing the strongest possible guarantees as a safe default choice.
 * On failure no memory order is enforced (relaxed).
 *
 * If required, use one of the variants that explicitly specify the
 * memory order: relaxed, acquire, release, acq_rel or seq_cst
 *
 * \param mem     Pointer to the memory to change.
 * \param oldval  Only write 'newval' if the memory contains this value.
 * \param newval  Write this value if the memory contains 'oldval'.
 * \return True if the memory was written, false otherwise.
 */
template< typename T > inline
bool
cas(T *mem, T oldval, T newval)
{
  return cas_seq_cst<T>(mem, oldval, newval);
}
