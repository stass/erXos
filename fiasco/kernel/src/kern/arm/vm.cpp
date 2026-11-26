// Modified by erXos: the kernel debugger's parts are deleted (docs/design-debugger.md).
// Modified by erXos: FP state is switched eagerly, so no thread owns the
// FPU (docs/design-fiasco.md, "Eager FP switching").
INTERFACE [arm_em_tz]:

#include "task.h"

class Vm : public cxx::Dyn_castable<Vm, Task>
{
public:
  explicit Vm(Ram_quota *q)
    : Dyn_castable_class(q, Caps::mem() | Caps::obj()) {}

  struct Vm_state_mode
  {
    Mword sp;
    Mword lr;
    Mword spsr;
  };

  enum
  {
    Max_num_inject_irqs = 32 * 8,
    Nr_irq_fields = (Max_num_inject_irqs + (sizeof(Unsigned32) * 8 - 1))
                    / (sizeof(Unsigned32) * 8),
  };

  struct Vm_state_irq_inject
  {
    Unsigned32 group;
    Unsigned32 irqs[Nr_irq_fields];
  };

  struct Vm_state
  {
    Mword r[13];

    Mword sp_usr;
    Mword lr_usr;

    Vm_state_mode irq;
    Mword r_fiq[5]; // r8 - r12
    Vm_state_mode fiq;
    Vm_state_mode abt;
    Vm_state_mode und;
    Vm_state_mode svc;

    Mword pc;
    Mword cpsr;

    Mword pending_events;
    Unsigned32 cpacr;
    Mword cp10_fpexc;

    Mword pfs;
    Mword pfa;
    Mword exit_reason;

    Vm_state_irq_inject irq_inject;
  };

private:
  Vm_state *state_for_dbg;

  enum Exit_reasons
  {
    ER_none       = 0,
    ER_vmm_call   = 1,
    ER_inst_abort = 2,
    ER_data_abort = 3,
    ER_irq        = 4,
    ER_fiq        = 5,
    ER_undef      = 6,
  };

};

//-----------------------------------------------------------------------------
IMPLEMENTATION [arm]:

#include "cpu.h"
#include "cpu_lock.h"
#include "entry_frame.h"
#include "ipc_timeout.h"
#include "logdefs.h"
#include "mem_space.h"
#include "thread_state.h"
#include "timer.h"
#include "kmem_slab.h"

JDB_DEFINE_TYPENAME(Vm, "\033[33;1mVm\033[m");

static Kmem_slab_t<Vm> _vm_allocator("Vm");

PUBLIC inline virtual
Page_number
Vm::map_max_address() const
{ return Page_number(1UL << (MWORD_BITS - Mem_space::Page_shift)); }

PUBLIC static
Vm *Vm::alloc(Ram_quota *q)
{
  return _vm_allocator.q_new(q, q);
}

PUBLIC inline
void *
Vm::operator new([[maybe_unused]] size_t size, void *p) noexcept
{
  assert (size == sizeof(Vm));
  return p;
}

PUBLIC
void
Vm::operator delete(Vm *vm, std::destroying_delete_t)
{
  Ram_quota *q = vm->ram_quota();
  vm->~Vm();
  _vm_allocator.q_free(q, vm);
}

// ------------------------------------------------------------------------
IMPLEMENTATION [arm && arm_em_tz]:

#include "pic.h"
#include "thread.h"

PUBLIC
int
Vm::resume_vcpu(Context *ctxt, Vcpu_state *vcpu, [[maybe_unused]] bool user_mode)
  override
{
  assert(user_mode);

  assert(cpu_lock.test());

  if (!(ctxt->state(true) & Thread_ext_vcpu_enabled)) [[unlikely]]
    {
      ctxt->arch_load_vcpu_kern_state(vcpu, true);
      return -L4_err::EInval;
    }

  Vm_state *state = offset_cast<Vm_state *>(vcpu, Config::Ext_vcpu_state_offset);

  state_for_dbg = state;

  if (state->irq_inject.group)
    {
      Unsigned32 g = state->irq_inject.group;
      for (unsigned i = 1; i < Nr_irq_fields; ++i)
        if ((1 << i) & g)
          {
            Pic::set_pending_irq(i, state->irq_inject.irqs[i]);
            state->irq_inject.irqs[i] = 0;
          }

      state->irq_inject.group = 0;
    }

  while (true)
    {
      if (   !(vcpu->_saved_state & Vcpu_state::F_irqs)
          && (vcpu->sticky_flags & Vcpu_state::Sf_irq_pending))
        {
          state->exit_reason = ER_irq;
          ctxt->arch_load_vcpu_kern_state(vcpu, true);
          return 1;
        }

      log_vm(state, 1);

      if (!get_fpu())
        {
          ctxt->arch_load_vcpu_kern_state(vcpu, true);
          return -L4_err::EInval;
        }

      Cpu::cpus.current().tz_switch_to_ns(reinterpret_cast<Mword *>(state));

      assert(cpu_lock.test());

      log_vm(state, 0);

      if (state->exit_reason == ER_irq || state->exit_reason == ER_fiq)
        Proc::preemption_point();

      switch (state->exit_reason)
        {
        case ER_data_abort:
          if ((state->pfs & 0x237) == 0x211)
            break;
          ctxt->arch_load_vcpu_kern_state(vcpu, true);
          return 0;
        case ER_undef:
          printf("should not happen: %lx\n", state->pc);
          [[fallthrough]];
        case ER_vmm_call:
        case ER_inst_abort:
          ctxt->arch_load_vcpu_kern_state(vcpu, true);
          return 0;
        }

      Thread *t = nonull_static_cast<Thread*>(ctxt);
      if (t->continuation_test_and_restore())
        {
          ctxt->arch_load_vcpu_kern_state(vcpu, true);
          t->vcpu_return_to_kernel(vcpu->_entry_ip, vcpu->_entry_sp,
                                   t->vcpu_state().usr().get());
        }
    }
}

namespace {

static Kobject_iface * FIASCO_FLATTEN
vm_factory(Ram_quota *q, Space *,
           L4_msg_tag t, Utcb const *u, Utcb *out,
           int *err, unsigned *words)
{
  return Task::create<Vm>(q, t, u, out, err, words);
}

static inline
void __attribute__((constructor)) FIASCO_INIT_SFX(vm_register_factory)
register_factory()
{
  Kobject_iface::set_factory(L4_msg_tag::Label_vm, vm_factory);
}

}

// --------------------------------------------------------------------------
IMPLEMENTATION [arm && arm_em_tz]:

// FP state is switched eagerly, so the current thread's state is always
// loaded and a world switch needs nothing from the FPU.
PUBLIC
bool
Vm::get_fpu()
{ return true; }

// --------------------------------------------------------------------------
IMPLEMENTATION [!debug && arm_em_tz]:

PUBLIC static inline
void
Vm::log_vm(Vm_state *, bool)
{}
