// Modified by erXos: map_trace maps the kernel's trace rings read-only into the
// root (docs/design-fiasco.md, "The kernel's trace rings").
INTERFACE:

#include "kobject_helper.h"
#include "platform_control.h"
#include "irq_controller.h"
#include "reset.h"
#include "global_data.h"

class Platform_control_object : public Kobject_h<Platform_control_object, Icu>
{
public:
  enum class Op : Mword
  {
    Suspend_system     = 0x0,
    Shutdown_system    = 0x1,
    Allow_cpu_shutdown = 0x2,
    Set_task_asid_arm  = 0x10,
    // erXos: maps the kernel's trace rings read-only into the caller
    // (Erx_trace::map_trace, ERX_FIASCO_PFC_MAP_TRACE).
    Erx_map_trace      = 0x100,
  };

private:
  static Global_data<Platform_control_object> pfc;

protected:
  L4_msg_tag invoke_arch(L4_fpage::Rights rights, Syscall_frame *f,
                         Utcb const *r_msg, Utcb *s_msg);
};

//-----------------------------------------------------------------------------
IMPLEMENTATION:

#include "erx_trace.h"
#include "globals.h"
#include "task.h"

JDB_DEFINE_TYPENAME(Platform_control_object, "Icu/Pfc");

DEFINE_GLOBAL Global_data<Platform_control_object> Platform_control_object::pfc;

/*
 * L4-IFACE: kernel-pfc.pfc-cpu_allow_shutdown
 * PROTOCOL: L4_PROTO_PLATFORM_CTL
 */
PRIVATE inline
L4_msg_tag
Platform_control_object::sys_cpu_allow_shutdown(L4_fpage::Rights,
                                                Syscall_frame *f,
                                                Utcb const *utcb)
{
  // silently ignore it if we have no support for it
  if (!Platform_control::cpu_shutdown_available())
    return commit_result(0);

  if (f->tag().words() < 3)
    return commit_result(-L4_err::EInval);

  Cpu_number cpu = Cpu_number(utcb->values[1]);

  if (cpu >= Cpu::invalid() || !Per_cpu_data::valid(cpu))
    return commit_result(-L4_err::EInval);

  return commit_result(Platform_control::cpu_allow_shutdown(cpu, utcb->values[2]));
}

/*
 * L4-IFACE: kernel-pfc.pfc-system_suspend
 * PROTOCOL: L4_PROTO_PLATFORM_CTL
 */
PRIVATE inline
L4_msg_tag
Platform_control_object::sys_system_suspend(L4_fpage::Rights, Syscall_frame *f,
                                            Utcb const *msg)
{
  Mword extra = 0;
  if (f->tag().words() >= 2)
    extra = msg->values[1];

  return commit_result(Platform_control::system_suspend(extra));
}

/*
 * L4-IFACE: kernel-pfc.pfc-system_shutdown
 * PROTOCOL: L4_PROTO_PLATFORM_CTL
 */
PRIVATE inline
L4_msg_tag
Platform_control_object::sys_system_shutdown(L4_fpage::Rights, Syscall_frame *f,
                                             Utcb const *msg)
{
  if (f->tag().words() != 2)
    return commit_result(-L4_err::EInval);

  if (msg->values[1] == 1) // reboot?
    Platform_control::system_reboot();

  if (msg->values[1] == 0) // shutdown
    Platform_control::system_off();

  // There's no generic in-kernel way for system power-off
  return commit_result(-L4_err::ENosys);
}

/*
 * erXos: map_trace, which maps the kernel's trace rings read-only into the
 * caller (docs/design-fiasco.md, "The kernel's trace rings"). Decodes the
 * message here, in Fiasco's own types, and hands Erx_trace plain values.
 */
PRIVATE inline
L4_msg_tag
Platform_control_object::sys_erx_map_trace(Syscall_frame *f, Utcb const *msg)
{
  unsigned const words = f->tag().words();
  L4_fpage window(words >= 2 ? msg->values[1] : 0);
  bool const mempage = words >= 2 && window.is_valid() && window.is_mempage();

  return commit_result(Erx_trace::map_trace(
    static_cast<Task *>(current()->space()), words, mempage,
    mempage ? cxx::int_value<Virt_addr>(window.mem_address()) : 0,
    mempage ? window.order() : 0));
}

PUBLIC inline
L4_msg_tag
Platform_control_object::kinvoke(L4_obj_ref ref, L4_fpage::Rights rights,
                                 Syscall_frame *f, Utcb const *r_msg,
                                 Utcb *s_msg)
{
  L4_msg_tag tag = f->tag();

  if (tag.proto() == L4_msg_tag::Label_irq)
    return Icu::icu_invoke(ref, rights, f, r_msg, s_msg);

  if (!Ko::check_basics(&tag, L4_msg_tag::Label_platform_ctl))
    return tag;

  switch (static_cast<Op>(r_msg->values[0]))
    {
    case Op::Suspend_system:     return sys_system_suspend(rights, f, r_msg);
    case Op::Shutdown_system:    return sys_system_shutdown(rights, f, r_msg);
    case Op::Allow_cpu_shutdown: return sys_cpu_allow_shutdown(rights, f, r_msg);
    case Op::Erx_map_trace:      return sys_erx_map_trace(f, r_msg);
    default:                     return invoke_arch(rights, f, r_msg, s_msg);
    }
}

IMPLEMENT_DEFAULT inline
L4_msg_tag
Platform_control_object::invoke_arch(L4_fpage::Rights, Syscall_frame *,
                                     Utcb const *, Utcb *)
{ return commit_result(-L4_err::ENosys); }
