// Modified by erXos: the kernel debugger's parts are deleted (docs/design-debugger.md).
INTERFACE:

#include "l4_types.h"
#include "cxx/bitfield"

/**
 * Generic constants for x86 segment descriptors.
 */
class X86desc
{
public:
  /**
   * Accessed bit in segment descriptor.
   */
  enum Access : Unsigned8
  {
    Not_accessed = 0x00,
    Accessed     = 0x01
  };

  /**
   * Type bits (code/data, expand-down/conforming, write/read) in non-system
   * segment descriptor.
   */
  enum Type : Unsigned8
  {
    Data_write = 0x01,
    Code_read  = 0x05
  };

  /**
   * System segment descriptor and gate descriptor types.
   */
  enum Type_system : Unsigned8
  {
    Ldt           = 0x02,
    Task_gate     = 0x05,
    Tss_available = 0x09,
    Tss_busy      = 0x0b,
    Intr_gate     = 0x0e,
    Trap_gate     = 0x0f
  };

  /**
   * Descriptor privilege level bits.
   */
  enum Dpl : Unsigned8
  {
    Kernel = 0x00,
    User   = 0x03
  };

  /**
   * 64-bit code segment (L) bit in segment descriptor.
   */
  enum Code : Unsigned8
  {
    Code_undef  = 0x00,
    Code_compat = 0x00,
    Code_64bit  = 0x01
  };

  /**
   * Default operation size bits in segment descriptor.
   */
  enum Default_size : Unsigned8
  {
    Size_undef = 0x00,
    Size_16    = 0x00,
    Size_32    = 0x01
  };

  /**
   * Limit granularity bit in segment descriptor.
   */
  enum Granularity : Unsigned8
  {
    Granularity_bytes = 0x00,
    Granularity_4k    = 0x01
  };
};

/**
 * Global Descriptor Table segment descriptor.
 *
 * \note The value of the \ref _not_system bit determines whether the
 *       \ref _accessed and \ref _type bits or the \ref _type_system bits
 *       are valid.
 */
class Gdt_entry : public X86desc
{
private:
  Unsigned64 _value;

  CXX_BITFIELD_MEMBER(0, 15, _limit_low, _value);
  CXX_BITFIELD_MEMBER(16, 32 + 7, _base_low, _value);

  CXX_BITFIELD_MEMBER(32 + 8, 32 + 8, _accessed, _value);
  CXX_BITFIELD_MEMBER(32 + 9, 32 + 11, _type, _value);

  CXX_BITFIELD_MEMBER(32 + 8, 32 + 11, _type_system, _value);

  CXX_BITFIELD_MEMBER(32 + 12, 32 + 12, _not_system, _value);
  CXX_BITFIELD_MEMBER(32 + 13, 32 + 14, _dpl, _value);
  CXX_BITFIELD_MEMBER(32 + 15, 32 + 15, _present, _value);
  CXX_BITFIELD_MEMBER(32 + 16, 32 + 19, _limit_high, _value);
  CXX_BITFIELD_MEMBER(32 + 20, 32 + 20, _available, _value);
  CXX_BITFIELD_MEMBER(32 + 21, 32 + 21, _code, _value);
  CXX_BITFIELD_MEMBER(32 + 22, 32 + 22, _default_size, _value);
  CXX_BITFIELD_MEMBER(32 + 23, 32 + 23, _granularity, _value);
  CXX_BITFIELD_MEMBER(32 + 24, 32 + 31, _base_high, _value);
};

/**
 * Interrupt Descriptor Table gate descriptor.
 */
class Idt_entry : public X86desc
{
private:
  Unsigned64 _value;

  CXX_BITFIELD_MEMBER(0, 15, _offset_low, _value);
  CXX_BITFIELD_MEMBER(16, 31, _selector, _value);
  CXX_BITFIELD_MEMBER(32 + 0, 32 + 2, _ist, _value);
  CXX_BITFIELD_MEMBER(32 + 3, 32 + 7, _zeroes, _value);
  CXX_BITFIELD_MEMBER(32 + 8, 32 + 11, _type_system, _value);
  CXX_BITFIELD_MEMBER(32 + 12, 32 + 12, _not_system, _value);
  CXX_BITFIELD_MEMBER(32 + 13, 32 + 14, _dpl, _value);
  CXX_BITFIELD_MEMBER(32 + 15, 32 + 15, _present, _value);
  CXX_BITFIELD_MEMBER(32 + 16, 32 + 31, _offset_med, _value);
};

/**
 * Pseudo descriptor pointing to a GDT/IDT.
 */
class Pseudo_descriptor
{
private:
  Unsigned16 _limit;
  Address _base;
} __attribute__((packed));

//----------------------------------------------------------------------------
INTERFACE [amd64]:

EXTENSION class Idt_entry
{
private:
  Unsigned64 _value_high = 0;

  CXX_BITFIELD_MEMBER(0, 31, _offset_high, _value_high);
  CXX_BITFIELD_MEMBER(32, 63, _reserved, _value_high);
};

//----------------------------------------------------------------------------
IMPLEMENTATION:

#include <cassert>
#include "processor.h"

/**
 * Create a system segment descriptor.
 *
 * \note On AMD64, the second half of the system segment descriptor has to be
 *       created separately.
 *
 * \param base         Segment base address.
 * \param limit        Segment limit (already pre-shifted in case of 4K
 *                     granularity).
 * \param type_system  Type of the system segment descriptor.
 * \param dpl          Descriptor privilege level.
 * \param granularity  Limit granularity.
 */
PUBLIC constexpr
Gdt_entry::Gdt_entry(Address base, Unsigned32 limit,
                     Gdt_entry::Type_system type_system,
                     Gdt_entry::Dpl dpl, Gdt_entry::Granularity granularity)
  : _value(0)
{
  _limit_low() = limit & 0x0000ffffU;
  _base_low() = base & 0x00ffffffU;
  _type_system() = type_system;
  _not_system() = 0;
  _dpl() = dpl;
  _present() = 1;
  _limit_high() = (limit & 0x00f0000U) >> 16;
  _available() = 0;
  _code() = 0;
  _default_size() = 0;
  _granularity() = granularity;
  _base_high() = (base & 0xff000000U) >> 24;
}

/**
 * Create a non-present segment descriptor.
 */
PUBLIC constexpr
Gdt_entry::Gdt_entry()
  : _value(0)
{
}

/**
 * Create a non-system segment descriptor.
 *
 * \param base          Segment base address.
 * \param limit         Segment limit (already pre-shifted in case of 4K
 *                      granularity).
 * \param accessed      Accessed bit.
 * \param type          Segment type.
 * \param code          64-bit code segment flag (should be set to Code_undef
 *                      in case of data segments and for IA-32).
 * \param default_size  Default operation size (should be set to Size_undef
 *                      in case of 64-bit code segments).
 * \param granularity   Limit granularity.
 */
PUBLIC constexpr NEEDS[<cassert>, "processor.h"]
Gdt_entry::Gdt_entry(Address base, Unsigned32 limit,
                     Gdt_entry::Access accessed, Gdt_entry::Type type,
                     Gdt_entry::Dpl dpl, Gdt_entry::Code code,
                     Gdt_entry::Default_size default_size,
                     Gdt_entry::Granularity granularity)
  : _value(0)
{
  assert(Proc::Is_64bit || code == Code_undef);
  assert(type == Code_read || code == Code_undef);
  assert(code != Code_64bit || default_size == Size_undef);

  _limit_low() = limit & 0x0000ffffU;
  _base_low() = base & 0x00ffffffU;
  _accessed() = accessed;
  _type() = type;
  _not_system() = 1;
  _dpl() = dpl;
  _present() = 1;
  _limit_high() = (limit & 0x00f0000U) >> 16;
  _available() = 0;
  _code() = code;
  _default_size() = default_size;
  _granularity() = granularity;
  _base_high() = (base & 0xff000000U) >> 24;
}

/**
 * Get accessed bit.
 *
 * \return Accessed bit.
 */
PUBLIC inline
bool
Gdt_entry::accessed() const
{
  return _accessed();
}

/**
 * Get non-system segment type.
 *
 * \return Non-system segment type.
 */
PUBLIC inline NEEDS[<cassert>, Gdt_entry::system]
Gdt_entry::Type
Gdt_entry::type() const
{
  assert(!system());

  Unsigned8 type = _type();
  return static_cast<Gdt_entry::Type>(type);
}

/**
 * Get system segment type.
 *
 * \return System segment type.
 */
PUBLIC inline NEEDS[<cassert>, Gdt_entry::system]
Gdt_entry::Type_system
Gdt_entry::type_system() const
{
  assert(system());

  Unsigned8 type_system = _type_system();
  return static_cast<Gdt_entry::Type_system>(type_system);
}

/**
 * Get whether the segment descriptor is of a system kind.
 *
 * Note that the hardware bit logic is inverted.
 *
 * \retval True if the segment descriptor is a system descriptor.
 * \retval False if the segment descriptor is a non-system descriptor.
 */
PUBLIC inline
bool
Gdt_entry::system() const
{
  return !_not_system();
}

/**
 * Get whether a non-system segment is writeable.
 *
 * \retval True if the non-system segment is writeable.
 * \retval False if the non-system segment is not writeable.
 */
PUBLIC inline NEEDS[<cassert>, Gdt_entry::system]
bool
Gdt_entry::writable() const
{
  assert(!system());
  return !!(_type() & 0x02);
}

/**
 * Get descriptor privilege level.
 *
 * \return Descriptor privilege level.
 */
PUBLIC inline
Gdt_entry::Dpl
Gdt_entry::dpl() const
{
  Unsigned8 dpl = _dpl();
  return static_cast<Gdt_entry::Dpl>(dpl);
}

/**
 * Get whether the segment is present.
 *
 * \retval True if the segment is present.
 * \retval False if the segment is not present.
 */
PUBLIC inline
bool
Gdt_entry::present() const
{
  return _present();
}

/**
 * Get segment limit.
 *
 * \return Segment limit (raw value).
 */
PUBLIC inline
Unsigned32
Gdt_entry::limit() const
{
  return static_cast<Unsigned32>(_limit_low())
         | (static_cast<Unsigned32>(_limit_high()) << 16);
}

/**
 * Get segment size.
 *
 * \return Actual segment size in bytes, depending on the limit and the limit
 *         granularity.
 */
PUBLIC inline NEEDS[Gdt_entry::granularity, Gdt_entry::limit]
Mword
Gdt_entry::size() const
{
  Mword value = limit();

  if (granularity() == Granularity_4k)
    return ((value + 1) << 12) - 1;

  return value;
}

/**
 * Get segment limit granularity.
 *
 * \return Segment limit granularity.
 */
PUBLIC inline
Gdt_entry::Granularity
Gdt_entry::granularity() const
{
  Unsigned8 granularity = _granularity();
  return static_cast<Gdt_entry::Granularity>(granularity);
}

/**
 * Get segment available bit.
 *
 * \return Segment available bit.
 */
PUBLIC inline
bool
Gdt_entry::available() const
{
  return _available();
}

/**
 * Get code segment flag.
 *
 * \return Code segment flag (64-bit/compatibility).
 */
PUBLIC inline
Gdt_entry::Code
Gdt_entry::code() const
{
  Unsigned8 code = _code();
  return static_cast<Gdt_entry::Code>(code);
}

/**
 * Get segment default operation size.
 *
 * \return Segment default operation size.
 */
PUBLIC inline
Gdt_entry::Default_size
Gdt_entry::default_size() const
{
  Unsigned8 default_size = _default_size();
  return static_cast<Gdt_entry::Default_size>(default_size);
}

/**
 * Get whether the segment descriptor is unsafe for user access.
 *
 * A segment descriptor is unsafe if its privilege level is not user space or
 * if it is a system descriptor.
 *
 * \retval True if segment descriptor is unsafe for user access.
 * \retval False if segment descriptor is safe for user access.
 */
PUBLIC inline NEEDS[Gdt_entry::present, Gdt_entry::dpl, Gdt_entry::system]
bool
Gdt_entry::unsafe() const
{
  return present() && ((dpl() != User) || system());
}

/**
 * Make a TSS entry available.
 *
 * Turn a TSS entry into a TSS Available entry.
 */
PUBLIC inline NEEDS[<cassert>, Gdt_entry::system, Gdt_entry::type_system]
void
Gdt_entry::tss_make_available()
{
  assert(system());
  assert(type_system() == Tss_available || type_system() == Tss_busy);

  _type_system() = Tss_available;
}

/**
 * Create a non-present gate descriptor.
 */
PUBLIC constexpr
Idt_entry::Idt_entry()
  : _value(0)
{
}

/**
 * Get descriptor privilege level.
 *
 * \return Descriptor privilege level.
 */
PUBLIC inline
Idt_entry::Dpl
Idt_entry::dpl() const
{
  Unsigned8 dpl = _dpl();
  return static_cast<Idt_entry::Dpl>(dpl);
}

/**
 * Get whether the gate is present.
 *
 * \retval True if the gate is present.
 * \retval False if the gate is not present.
 */
PUBLIC inline
bool
Idt_entry::present() const
{
  return _present();
}

/**
 * Create an empty pseudo descriptor.
 */
PUBLIC constexpr
Pseudo_descriptor::Pseudo_descriptor()
  : _limit(0), _base(0)
{
}

/**
 * Create a pseudo descriptor.
 *
 * \param base   Base address.
 * \param limit  Limit.
 */
PUBLIC constexpr
Pseudo_descriptor::Pseudo_descriptor(Address base, Unsigned16 limit)
  : _limit(limit), _base(base)
{
}

/**
 * Get pseudo descriptor base address.
 *
 * \return Pseudo descriptor base address.
 */
PUBLIC inline
Address
Pseudo_descriptor::base() const
{
  return _base;
}

/**
 * Get pseudo descriptor limit.
 *
 * \return Pseudo descriptor limit.
 */
PUBLIC inline
Unsigned16
Pseudo_descriptor::limit() const
{
  return _limit;
}

//----------------------------------------------------------------------------
IMPLEMENTATION [ia32]:

/**
 * Get segment base address.
 *
 * \return Segment base address.
 */
PUBLIC inline
Address
Gdt_entry::base() const
{
  return static_cast<Address>(_base_low())
         | (static_cast<Address>(_base_high()) << 24);
}

/**
 * Create an interrupt/trap gate descriptor.
 *
 * \param offset       Offset.
 * \param selector     Target selector.
 * \param type_system  Descriptor type (Intr_gate or Trap_gate).
 * \param dpl          Descriptor privilege level.
 */
PUBLIC constexpr NEEDS[<cassert>]
Idt_entry::Idt_entry(Address offset, Unsigned16 selector,
                     Idt_entry::Type_system type_system, Idt_entry::Dpl dpl,
                     Unsigned8 = 0)
  : _value(0)
{
  assert(type_system == Intr_gate || type_system == Trap_gate);

  _offset_low() = offset & 0x0000ffffU;
  _selector() = selector;
  _ist() = 0;
  _zeroes() = 0;
  _type_system() = type_system;
  _not_system() = 0;
  _dpl() = dpl;
  _present() = 1;
  _offset_med() = (offset & 0xffff0000U) >> 16;
}

/**
 * Create a task gate descriptor.
 *
 * \param selector  Target selector.
 * \param dpl       Descriptor privilege level.
 */
PUBLIC constexpr
Idt_entry::Idt_entry(Unsigned16 selector, Idt_entry::Dpl dpl)
  : _value(0)
{
  _offset_low() = 0;
  _selector() = selector;
  _ist() = 0;
  _zeroes() = 0;
  _type_system() = Task_gate;
  _not_system() = 0;
  _dpl() = dpl;
  _present() = 1;
  _offset_med() = 0;
}

/**
 * Get gate descriptor offset.
 *
 * \return Gate descriptor offset.
 */
PUBLIC inline
Address
Idt_entry::offset() const
{
  return static_cast<Address>(_offset_low())
         | (static_cast<Address>(_offset_med()) << 16);
}

//----------------------------------------------------------------------------
IMPLEMENTATION[amd64]:

#include <panic.h>

/**
 * Create the second half of a system segment descriptor.
 *
 * \param base  Segment base address.
 */
PUBLIC constexpr
Gdt_entry::Gdt_entry(Address base)
  : _value(base >> 32)
{}

/**
 * Get segment base address.
 *
 * \return Segment base address.
 */
PUBLIC inline
Address
Gdt_entry::base() const
{
  Address base = static_cast<Address>(_base_low())
                 | (static_cast<Address>(_base_high()) << 24);

  if (_not_system())
    return base;

  /*
   * Long mode system segment descriptor occupies two 64-bit slots and the
   * upper 32 bits of the base address follow in the lower 32 bits of the next
   * 64-bit slot.
   */

  return base | (this[1]._value << 32);
}

/**
 * Create an interrupt/trap gate descriptor.
 *
 * \param offset       Offset.
 * \param selector     Target selector.
 * \param type_system  Descriptor type (Intr_gate or Trap_gate).
 * \param dpl          Descriptor privilege level.
 * \param ist          Interrupt stack table.
 */
PUBLIC constexpr NEEDS[<cassert>]
Idt_entry::Idt_entry(Address offset, Unsigned16 selector,
                     Idt_entry::Type_system type_system, Idt_entry::Dpl dpl,
                     Unsigned8 ist = 0)
  : _value(0)
{
  assert(type_system == Intr_gate || type_system == Trap_gate);

  _offset_low() = offset & 0x000000000000ffffULL;
  _selector() = selector;
  _ist() = ist;
  _zeroes() = 0;
  _type_system() = type_system;
  _not_system() = 0;
  _dpl() = dpl;
  _present() = 1;
  _offset_med() = (offset & 0x00000000ffff0000ULL) >> 16;
  _offset_high() = (offset & 0xffffffff00000000ULL) >> 32;
  _reserved() = 0;
}

/**
 * Create a task gate descriptor.
 *
 * This method panics as there are no task gate descriptors on AMD64.
 * The code exists to preserve a common API with IA-32.
 */
PUBLIC
Idt_entry::Idt_entry(Unsigned16, Idt_entry::Dpl)
{
  panic("AMD64 does not support task gates");
}

/**
 * Get gate descriptor offset.
 *
 * \return Gate descriptor offset.
 */
PUBLIC inline
Address
Idt_entry::offset() const
{
  return static_cast<Address>(_offset_low())
         | (static_cast<Address>(_offset_med()) << 16)
         | (static_cast<Address>(_offset_high()) << 32);
}

//----------------------------------------------------------------------------
