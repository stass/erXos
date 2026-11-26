// Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
// SPDX-License-Identifier: BSD-2-Clause
//
// The stop of the machine on Fiasco (docs/design-debugger.md, "The stop" and
// "On Fiasco"): the effects around the decisions of kernel/core/machine_stop.c.
// Every fatal stop of the kernel enters here and none returns. The claim
// swaps the anchor's stop word; the leader moves to its CPU's panic stack,
// asks every admitted CPU to stop with the debug inter-processor interrupt,
// takes the census on the system clock, writes the crash record with each
// CPU's entry and prints its frame, and resets the machine. A CPU asked to
// stop publishes the registers its interrupt interrupted and parks; a CPU
// that starts into a stopped machine parks at its admission.
//
// What is glue memory and how it is ordered:
//  - the stop word is the anchor's, set once by one compare-and-swap and
//    never cleared;
//  - the admitted set is one word, a bit per kernel CPU number, set by a
//    fetch-or at each CPU's admission and never cleared;
//  - each CPU's stop slot is written by that CPU alone, its state last with
//    release ordering, and read by the leader, state first with acquire;
//  - each CPU's depth and its hardware identifier are written by that CPU
//    alone: the depth at each entry into a stop path, the identifier at its
//    admission and, for the boot CPU, at the glue's setup. A CPU finds its
//    own number by its hardware identifier in
//    that table, so the stop trusts no per-CPU pointer of the failing state.
INTERFACE:

#include <cstdarg>
#include <cstddef>
#include "types.h"

class Return_frame;
class Trap_state;

class Erx_machine_stop
{
public:
  // A panic, a failed assertion or kdb_ke: cause panic, the call site's
  // registers as the leader's.
  [[noreturn]] static void panic(char const *format, va_list args);
  [[noreturn]] static void stop(char const *format, ...)
    __attribute__((format(printf, 1, 2)));
  // A kernel trap: the trap's frame as the leader's registers, the
  // exception in the record's fault field, and what as the message's
  // start, with the exception's class.
  [[noreturn]] static void trap(Trap_state const *ts, char const *what);
};

IMPLEMENTATION:

#include <cstdio>
#include <libc_backend.h>
#include "erx/core/crash.h"
#include "erx/core/effects.h"
#include "erx/core/machine_stop.h"
#include "config.h"
#include "context_base.h"
#include "cpu.h"
#include "entry_frame.h"
#include "erx_console_ring.h"
#include "erx_stop_offsets.h"
#include "ipi.h"
#include "mem.h"
#include "platform_control.h"
#include "processor.h"
#include "timer.h"
#include "trap_state.h"

// The registers a stop records for the CPU that runs it, and the routine,
// in kern/arm/64/ivt.S, that saves them at its call site, moves to stack_top
// and calls body(arg) there, never to return.
extern "C" [[noreturn]] void
erx_machine_stop_switch(erx_stop_regs_t *regs, void *stack_top,
                        void (*body)(void *), void *arg);
// The offsets kern/arm/64/ivt.S stores at, from kern/arm/64/erx_stop_offsets.h,
// which assembly cannot take from the generated layout, held to it here.
static_assert(offsetof(erx_stop_regs_t, regs) == 0 && ERX_REGS_OFF_GPR == STOP_GPR(0)
              && STOP_GPR(1) == 8 && ERX_REGS_OFF_SP == STOP_SP && ERX_REGS_OFF_PC == STOP_PC
              && ERX_REGS_OFF_STATE == STOP_STATE
              && ERX_STOP_REGS_OFF_SPACE_ROOT == STOP_SPACE_ROOT
              && ERX_STOP_REGS_OFF_CAUSE == STOP_CAUSE && ERX_STOP_REGS_OFF_ADDR == STOP_ADDR,
              "ivt.S stores a stopped CPU's registers at the ABI's offsets");

// The two system registers a stop request reads live: the space's translation
// root, as erx_machine_stop_switch records it, and the user's stack pointer,
// which the interrupt entry does not save. erx_machine_stop_live, in
// kern/arm/64/ivt.S, stores them at offsets 0 and 8.
struct Erx_stop_live
{
  Mword space_root;
  Mword user_sp;
};
extern "C" void erx_machine_stop_live(Erx_stop_live *live);
static_assert(offsetof(Erx_stop_live, space_root) == 0 && offsetof(Erx_stop_live, user_sp) == 8
              && sizeof(Erx_stop_live) == 16, "erx_machine_stop_live stores the two words with one stp");

static_assert(Config::Max_num_cpus <= ERX_CPU_LIMIT,
              "every CPU the kernel can start has a stop slot and a bit");
static_assert(sizeof(Mword) == sizeof(uint64_t), "a register is a slot's word");

namespace {

// Each CPU's panic stack is one thread block, aligned as Fiasco's own, so
// Fiasco's lookup of the current thread through the stack pointer lands on its
// first bytes: a header shaped as Fiasco's Context_base, its CPU number set at
// the glue's setup and every other word zero, so the lookup finds that CPU and
// no thread, never the stack's bytes read as one. Above the header it holds
// the formatted message, the crash core's writer and the frame's printer below
// the leader's own frames.
enum { Panic_stack_bytes = Context_base::Size, Message_bytes = 512 };
static_assert(Panic_stack_bytes >= 2 * ERX_PAGE_SIZE, "a panic stack is two pages at least");

// How many times the leader tries to take the printf lock before it prints
// without it (docs/design-debugger.md, "The stop", step 6).
enum { Lock_tries = 100000 };

// How long the census waits before it asks a silent CPU again.
static constexpr uint64_t Ask_again_ns = 1000000;

struct alignas(Panic_stack_bytes) Panic_stack { unsigned char bytes[Panic_stack_bytes]; };

// What a stop's entry hands the leader on its panic stack: the registers the
// stop records, which are the call site's for a panic and the trap's frame
// for a trap, whose call site's registers go to site, and the record's fault
// field, zero but for a trap.
struct Entry
{
  unsigned cpu;
  char const *format;
  va_list *args;
  erx_fault_t fault;
  erx_stop_regs_t regs;
  erx_stop_regs_t site;
};

}

// The anchor, whose stop word is the claim. Its magic and version mark the
// page; the rest of it is completed with the hold (docs/design-debugger.md,
// "The anchor"), and until then its crc is zero, which every reader refuses.
alignas(ERX_PAGE_SIZE) static erx_debug_anchor_t erx_debug_anchor = {
  ERX_DEBUG_ANCHOR_MAGIC_BYTES, ERX_DEBUG_ANCHOR_VERSION, 0, {}, 0, 0, 0, 0, 0,
  0, 0, 0, {}, {}, {}
};

static erx_machine_stop_slot_t erx_stop_slots[ERX_CPU_LIMIT];
static uint64_t erx_stop_admitted;
static uint32_t erx_stop_depth[ERX_CPU_LIMIT];
// Each admitted CPU's hardware identifier plus one; zero for no CPU.
static uint64_t erx_stop_hwid[ERX_CPU_LIMIT];
static Panic_stack erx_panic_stacks[Config::Max_num_cpus];

// The interrupt entry's frame and the stack pointer it interrupted, per CPU,
// for the interrupt being dispatched (erx_machine_stop_irq_frame).
static Return_frame *erx_irq_frame[Config::Max_num_cpus];
static Mword erx_irq_sp[Config::Max_num_cpus];

// What the leader alone writes, after its claim.
static char erx_stop_message[Message_bytes];
alignas(ERX_CRASH_BUFFER_ALIGN) static unsigned char erx_crash_buffer[ERX_CRASH_SIZE];
alignas(ERX_CRASH_BUFFER_ALIGN) static unsigned char erx_crash_scratch[ERX_CRASH_SCRATCH_BYTES];

// The record's form, from the boot image's development flag; the brief form
// until the handoff is read, so an early stop records no registers.
static uint32_t erx_stop_form = ERX_CRASH_FORM_BRIEF;
static uint8_t erx_stop_build_id[ERX_BUILD_ID_SIZE];

// This CPU's kernel number (erx_machine_stop_self): its hardware identifier's
// entry in the table; before the glue's setup the boot CPU; and for a CPU
// not yet admitted the number Fiasco keeps for it, through the stack pointer,
// which is read only then.
static unsigned
erx_stop_cpu()
{
  uint64_t const id = Cpu::mpidr() + 1;
  unsigned found = Config::Max_num_cpus;
  for (unsigned cpu = 0; cpu < Config::Max_num_cpus && found == Config::Max_num_cpus; ++cpu)
    if (__atomic_load_n(&erx_stop_hwid[cpu], __ATOMIC_RELAXED) == id)
      found = cpu;
  unsigned const boot = cxx::int_value<Cpu_number>(Cpu_number::boot_cpu());
  bool const boot_set = __atomic_load_n(&erx_stop_hwid[boot], __ATOMIC_RELAXED) != 0;
  unsigned const cpu = erx_machine_stop_self(found, Config::Max_num_cpus, boot_set, boot);
  return cpu < Config::Max_num_cpus ? cpu : cxx::int_value<Cpu_number>(current_cpu());
}

// Every claim and every park goes through here first, so a CPU that faults
// after any write to its slot claims at depth two or more.
static uint32_t
erx_stop_deeper(unsigned cpu)
{
  return ++erx_stop_depth[cpu];
}

[[noreturn]] static void
erx_stop_park()
{
  for (;;)
    {
      Proc::cli();
      Proc::pause();
    }
}

static void
erx_stop_publish(unsigned cpu, erx_stop_cpu_state_t state,
                 erx_stop_regs_t const &regs, uint64_t aux)
{
  erx_machine_stop_slot_t *slot = &erx_stop_slots[cpu];
  slot->aux = aux;
  slot->regs = regs;
  __atomic_store_n(&slot->state, state, __ATOMIC_RELEASE);
}

// The last line names the end, unless the end is a nested stop's silent one,
// whose print may be what faulted.
[[noreturn]] static void
erx_stop_end(unsigned cpu, bool say = true)
{
  static char const line[] = "erx: end reset\n";
  if (say)
    Erx_console_ring::write_uart(line, sizeof(line) - 1);
  // Fiasco finds the current CPU through the stack pointer, which on a panic
  // stack names no thread, so the reset is told the stop's own number.
  // A CPU whose number is out of range resets as the boot CPU, so the reset
  // never indexes past its per-CPU tables.
  Platform_control::system_reboot_from(Cpu_number(cpu < Config::Max_num_cpus ? cpu : 0));
}

static uint64_t
erx_stop_clock_ns()
{
  return Timer::system_clock() * 1000;
}

// The CPUs whose slots name them as having published for themselves.
static uint64_t
erx_stop_published(uint64_t asked)
{
  uint64_t published = 0;
  for (unsigned cpu = 0; cpu < ERX_CPU_LIMIT; ++cpu)
    if ((asked >> cpu) & 1
        && erx_machine_stop_published(__atomic_load_n(&erx_stop_slots[cpu].state,
                                                       __ATOMIC_ACQUIRE)))
      published |= uint64_t{1} << cpu;
  return published;
}

// The stop request to each CPU of cpus but the leader. The claim's store
// must be visible before each request: on GICv3 the request is a write of a
// system register, which a memory barrier does not order, so a dsb completes
// the store first.
static void
erx_stop_ask(unsigned leader, uint64_t cpus)
{
  Mem::dsb();
  for (unsigned other = 0; other < Config::Max_num_cpus; ++other)
    if (other != leader && (cpus >> other) & 1)
      Ipi::send(Ipi::Debug, Cpu_number(leader), Cpu_number(other));
}

// The leader's steps from its claim to the end of the census.
static erx_stop_leader_t
erx_stop_census(unsigned cpu)
{
  erx_stop_leader_t leader = erx_machine_stop_leader_begin(cpu);
  uint64_t asked_ns = 0;
  for (;;)
    {
      uint64_t loaded = 0;
      uint64_t now = 0;
      switch (leader.step)
        {
        case ERX_STOP_STEP_FENCE:
          __atomic_thread_fence(__ATOMIC_SEQ_CST);
          break;
        case ERX_STOP_STEP_LOAD_ADMITTED:
          loaded = __atomic_load_n(&erx_stop_admitted, __ATOMIC_RELAXED);
          break;
        case ERX_STOP_STEP_ASK:
          erx_stop_ask(cpu, leader.asked);
          now = erx_stop_clock_ns();
          asked_ns = now;
          break;
        case ERX_STOP_STEP_LOOK:
          loaded = erx_stop_published(leader.asked);
          now = erx_stop_clock_ns();
          // Ask again whoever has not answered, once a millisecond: a request
          // that a CPU took before it could see the claim's store, or that
          // its interrupt controller dropped, is not the census's last word
          // (docs/design-debugger.md, "Unverified facts", P7).
          if (now - asked_ns >= Ask_again_ns)
            {
              erx_stop_ask(cpu, leader.asked & ~loaded);
              asked_ns = now;
            }
          break;
        case ERX_STOP_STEP_RECORD:
          return leader;
        default:
          // No other step follows a claim that led.
          erx_stop_end(cpu);
        }
      leader = erx_machine_stop_leader_next(leader, loaded, now);
    }
}

// The CPUs the census covers: up to the highest CPU Fiasco has brought
// online, the leader's and every admitted one's.
static uint32_t
erx_stop_ncpus(unsigned leader)
{
  uint32_t n = leader + 1;
  uint64_t const admitted = __atomic_load_n(&erx_stop_admitted, __ATOMIC_RELAXED);
  for (unsigned cpu = 0; cpu < Config::Max_num_cpus; ++cpu)
    if (((admitted >> cpu) & 1 || Cpu::online(Cpu_number(cpu))) && cpu + 1 > n)
      n = cpu + 1;
  return n;
}

// A CPU's entry from its final state and its registers. The registers and
// aux are references and read only for a state that carries registers: a
// CPU that published such a state wrote them before its state, which the
// leader loaded with acquire, and one that did not may be writing them yet.
static void
erx_stop_entry(erx_crash_cpu_t *entry, erx_stop_cpu_state_t state,
               erx_stop_regs_t const &regs, uint64_t const &aux)
{
  entry->state = state;
  if (!erx_stop_cpu_state_registers(state))
    return;
  entry->pc = regs.regs.pc;
  entry->sp = regs.regs.sp;
  entry->fp = regs.regs.gpr[29];
  entry->return_address = regs.regs.gpr[30];
  entry->processor_state = regs.regs.state;
  entry->aux = aux;
}

// The leader's own frame pointers from its entry, at most ERX_CRASH_FRAMES:
// each record lies in the thread block that holds the stack pointer at the
// entry, at or above that stack pointer, and above the record before it, so a
// frame pointer the kernel's code did not keep ends the walk, never reads
// outside the stack.
static uint32_t
erx_stop_walk(erx_stop_regs_t const &regs, uint64_t *frames)
{
  // Only a kernel-mode stack (EL1) holds the kernel's frames.
  if ((regs.regs.state & 0xc) != 0x4)
    return 0;
  Mword const sp = regs.regs.sp;
  Mword const top = (sp & ~Mword{Context_base::Size - 1}) + Context_base::Size;
  Mword fp = regs.regs.gpr[29];
  uint32_t n = 0;
  while (n < ERX_CRASH_FRAMES && fp % 16 == 0 && fp >= sp && fp <= top - 16)
    {
      Mword const *record = reinterpret_cast<Mword const *>(fp);
      frames[n++] = record[1];
      if (record[0] <= fp)
        break;
      fp = record[0];
    }
  return n;
}

// One line of the report's first part, "erx: kernel stop: " and the text.
__attribute__((format(printf, 1, 2))) static void
erx_stop_say(char const *format, ...)
{
  static char const prefix[] = "erx: kernel stop: ";
  char line[160];
  va_list args;
  va_start(args, format);
  int const length = vsnprintf(line, sizeof(line) - 1, format, args);
  va_end(args);
  if (length < 0)
    return;
  size_t const used = size_t(length) < sizeof(line) - 1 ? size_t(length) : sizeof(line) - 2;
  line[used] = '\n';
  Erx_console_ring::write_uart(prefix, sizeof(prefix) - 1);
  Erx_console_ring::write_uart(line, used + 1);
}

// The report's first part (docs/design-debugger.md, "The stop", step 6): the
// record's own fields as text for the person at the console. After an
// incomplete census its first line names the CPUs that did not answer and
// whether the console's lock was taken. The message in
// every form, any control byte in it shown as '?'; in the full form the
// leader's registers and frames; and one line for each CPU with its state,
// and in the full form where it was.
static void
erx_stop_report(erx_crash_input_t const &input, erx_regs_t const &regs,
                erx_stop_leader_t const &leader, bool locked)
{
  using Ull = unsigned long long;
  if (!leader.complete)
    {
      char line[128];
      size_t used = size_t(snprintf(line, sizeof(line), "census %s",
                                    leader.complete ? "complete" : "incomplete: unanswered"));
      for (unsigned cpu = 0; cpu < input.ncpus && cpu < ERX_CRASH_CPUS; ++cpu)
        if (input.cpus[cpu].state == ERX_STOP_CPU_STATE_UNANSWERED && used < sizeof(line))
          used += size_t(snprintf(line + used, sizeof(line) - used, " %u", cpu));
      erx_stop_say("%s; console lock %s", line, locked ? "taken" : "not taken");
    }
  char message[Message_bytes];
  for (size_t at = 0; at < input.message_length; ++at)
    {
      unsigned char const c = input.message[at];
      message[at] = c >= 0x20 && c < 0x7f ? char(c) : '?';
    }
  message[input.message_length] = '\0';
  erx_stop_say("%s", message);
  bool const full = input.form == ERX_CRASH_FORM_FULL;
  if (full)
    {
      for (unsigned r = 0; r < 31; r += 4)
        {
          unsigned const last = r + 3 < 31 ? r + 3 : 30;
          char line[128];
          size_t used = 0;
          for (unsigned at = r; at <= last; ++at)
            if (used < sizeof(line))
              used += size_t(snprintf(line + used, sizeof(line) - used, "%sx%u 0x%016llx",
                                    at == r ? "" : " ", at,
                                    Ull(regs.gpr[at])));
          erx_stop_say("%s", line);
        }
      erx_stop_say("sp 0x%016llx pc 0x%016llx state 0x%llx",
                   Ull(regs.sp), Ull(regs.pc),
                   Ull(regs.state));
      for (unsigned at = 0; at < input.nframes; ++at)
        erx_stop_say("frame %u 0x%016llx", at, Ull(input.frames[at]));
    }
  for (unsigned cpu = 0; cpu < input.ncpus && cpu < ERX_CRASH_CPUS; ++cpu)
    {
      erx_crash_cpu_t const &entry = input.cpus[cpu];
      char const *const name = erx_stop_cpu_state_name(entry.state);
      if (full && erx_stop_cpu_state_registers(entry.state))
        erx_stop_say("cpu %u %s pc 0x%016llx sp 0x%016llx", cpu, name ? name : "unknown",
                     Ull(entry.pc), Ull(entry.sp));
      else
        erx_stop_say("cpu %u %s", cpu, name ? name : "unknown");
    }
}

// The leader, on its panic stack: the census, the record, its frame, the end.
[[noreturn]] static void
erx_stop_lead(void *arg)
{
  Entry *const entry = static_cast<Entry *>(arg);
  unsigned const cpu = entry->cpu;
  erx_stop_regs_t const &regs = entry->regs;
  // The leader's own slot, for a reader of the slots; the census counts none
  // of the leader's.
  erx_stop_publish(cpu, ERX_STOP_CPU_STATE_LEADER, regs, 0);
  erx_stop_leader_t const leader = erx_stop_census(cpu);
  // The console's lock, a bounded number of tries, kept to the machine's
  // end; a leader that failed while it held the lock holds it already. A
  // CPU that did not answer may hold it for good, so a failed take prints
  // without it, best effort, and never waits. It is taken before the
  // message is formatted, so a trap there finds the lock its own.
  bool const locked = __libc_backend_printf_take_bounded(Lock_tries) != 0;
  // The message is formatted once every CPU is asked, so an argument that
  // faults is a nested stop after the census, not before it.
  int const length = vsnprintf(erx_stop_message, sizeof(erx_stop_message),
                               entry->format, *entry->args);
  Erx_console_ring::close_at_stop();

  static erx_crash_cpu_t cpus[ERX_CRASH_CPUS];
  uint32_t const ncpus = erx_stop_ncpus(cpu);
  for (unsigned other = 0; other < ncpus && other < ERX_CRASH_CPUS; ++other)
    {
      // The census's last look decides who answered; a slot published since
      // stays out, so the record agrees with the census.
      erx_machine_stop_slot_t const *slot = &erx_stop_slots[other];
      erx_stop_cpu_state_t const published = __atomic_load_n(&slot->state, __ATOMIC_ACQUIRE);
      erx_stop_cpu_state_t const state = erx_machine_stop_final(&leader, other, published);
      if (other == cpu)
        erx_stop_entry(&cpus[other], state, regs, uint64_t{0});
      else
        erx_stop_entry(&cpus[other], state, slot->regs, slot->aux);
    }

  static uint64_t frames[ERX_CRASH_FRAMES];
  erx_crash_input_t input = {};
  input.form = erx_stop_form;
  input.cause = ERX_CRASH_CAUSE_PANIC;
  input.fault = entry->fault;
  input.cpu = cpu;
  input.nframes = erx_stop_walk(regs, frames);
  input.ncpus = ncpus;
  input.uptime_ns = erx_stop_clock_ns();
  for (unsigned at = 0; at < ERX_BUILD_ID_SIZE; ++at)
    input.build_id[at] = erx_stop_build_id[at];
  input.regs = &regs.regs;
  input.frames = frames;
  input.cpus = cpus;
  input.message = erx_stop_message;
  input.message_length = length < 0 ? 0 : (size_t(length) < sizeof(erx_stop_message) ? size_t(length) : sizeof(erx_stop_message) - 1);
  (void)erx_crash_record_write(&input, erx_crash_buffer, erx_crash_scratch);
  erx_stop_report(input, regs.regs, leader, locked);
  erx_crash_frame_write(erx_crash_buffer, ERX_CRASH_END_FAULT);
  erx_stop_end(cpu);
}

static void
erx_stop_nested_line()
{
  static char const line[] = "erx: nested stop\n";
  Erx_console_ring::write_uart(line, sizeof(line) - 1);
}

// Every stop's entry: the claim, then the leader's or a follower's move to
// its panic stack, or a nested stop's end. trapped is the trap's registers
// and fault the record's fault field, for a trap; null and zero for a
// panic, whose registers are the call site's. Nothing is written before
// the claim decides, so a nested entry leaves the leader's entry whole.
[[noreturn]] static void
erx_stop_enter(erx_stop_regs_t const *trapped, erx_fault_t const &fault,
               char const *format, va_list args)
{
  Proc::cli();
  static Entry entries[Config::Max_num_cpus];
  unsigned const cpu = erx_stop_cpu();
  if (cpu >= Config::Max_num_cpus)
    erx_stop_end(cpu, false);
  uint32_t const depth = erx_stop_deeper(cpu);
  uint32_t observed = 0;
  (void)__atomic_compare_exchange_n(&erx_debug_anchor.stop, &observed,
                                    erx_machine_stop_word(cpu), false,
                                    __ATOMIC_ACQ_REL, __ATOMIC_ACQUIRE);
  erx_stop_claim_t const claim = erx_machine_stop_claim(observed, cpu, depth);
  if (claim == ERX_STOP_NESTED)
    {
      erx_stop_nested_line();
      erx_stop_end(cpu);
    }
  if (claim == ERX_STOP_NESTED_SILENT)
    erx_stop_end(cpu, false);
  if (claim != ERX_STOP_LEAD && claim != ERX_STOP_FOLLOW)
    erx_stop_park();

  va_list copy;
  va_copy(copy, args);
  Entry *const entry = &entries[cpu];
  entry->cpu = cpu;
  entry->format = format;
  entry->args = &copy;
  entry->fault = fault;
  if (trapped)
    entry->regs = *trapped;
  void (*const body)(void *) = claim == ERX_STOP_LEAD
    ? erx_stop_lead
    : +[](void *arg)
        {
          Entry *const e = static_cast<Entry *>(arg);
          erx_stop_publish(e->cpu, ERX_STOP_CPU_STATE_CONCURRENT, e->regs, 0);
          erx_stop_park();
        };
  erx_machine_stop_switch(trapped ? &entry->site : &entry->regs,
                          erx_panic_stacks[cpu].bytes + Panic_stack_bytes, body, entry);
}

IMPLEMENT
void
Erx_machine_stop::panic(char const *format, va_list args)
{
  erx_stop_enter(nullptr, erx_fault_t{}, format, args);
}

IMPLEMENT
void
Erx_machine_stop::stop(char const *format, ...)
{
  va_list args;
  va_start(args, format);
  erx_stop_enter(nullptr, erx_fault_t{}, format, args);
}

[[noreturn]] __attribute__((format(printf, 3, 4))) static void
erx_stop_trapped(erx_stop_regs_t const &regs, erx_fault_t const &fault,
                 char const *format, ...)
{
  va_list args;
  va_start(args, format);
  erx_stop_enter(&regs, fault, format, args);
}

// A kernel-mode trap's frame (kern/arm/64/ivt.S) lies on the stack the
// trap found, just below the stack pointer it interrupted.
static_assert(sizeof(Trap_state) == sizeof(Return_frame),
              "a trap's frame is the entry's Return_frame and nothing more");

// A trap's fault address, kept only for the exception classes (ESR_EL1.EC)
// whose FAR_EL1 is the fault's: instruction and data aborts from either level
// and watchpoints, the classes FreeBSD's sys/arm64/arm64/trap.c reads it for
// (release/14.3.0, do_el1h_sync and do_el0_sync). Any other class gets zero:
// its frame's pf_address is a stale stack word (BRK) or a FAR_EL1 another
// domain's fault may have left, and the record leaves the machine. PC
// alignment's address is the pc and SP alignment's the stack pointer, both
// in the record already.
enum Erx_stop_ec : unsigned
{
  Ec_unknown = 0x00, Ec_iabt_lower = 0x20, Ec_iabt_same = 0x21, Ec_pc_align = 0x22,
  Ec_dabt_lower = 0x24, Ec_dabt_same = 0x25, Ec_sp_align = 0x26,
  Ec_watch_lower = 0x34, Ec_watch_same = 0x35, Ec_brk = 0x3c,
};

static constexpr Mword
stop_fault_addr(unsigned ec, Mword pf_address)
{
  bool far_is_fault = ec == Ec_iabt_lower || ec == Ec_iabt_same
                      || ec == Ec_dabt_lower || ec == Ec_dabt_same
                      || ec == Ec_watch_lower || ec == Ec_watch_same;
  return far_is_fault ? pf_address : 0;
}

// The trap's frame is the leader's registers, the exception's syndrome and
// fault address are their cause and address and, with its program counter,
// the record's fault field; nothing is printed before the stop's report.
IMPLEMENT
void
Erx_machine_stop::trap(Trap_state const *ts, char const *what)
{
  // Here, not beside stop_fault_addr: Fiasco's preprocessor places a free
  // function's definition after the file-scope code that follows it.
  static_assert(stop_fault_addr(Ec_dabt_same, 0x1000) == 0x1000
                && stop_fault_addr(Ec_iabt_lower, 0x1000) == 0x1000
                && stop_fault_addr(Ec_watch_same, 0x1000) == 0x1000,
                "an abort or a watchpoint keeps its fault address");
  static_assert(stop_fault_addr(Ec_brk, 0x1000) == 0 && stop_fault_addr(Ec_unknown, 0x1000) == 0
                && stop_fault_addr(Ec_pc_align, 0x1000) == 0
                && stop_fault_addr(Ec_sp_align, 0x1000) == 0,
                "a BRK, an unknown class or an alignment fault records no fault address");
  Proc::cli();
  erx_stop_regs_t regs = {};
  for (unsigned r = 0; r < 31; ++r)
    regs.regs.gpr[r] = ts->r[r];
  // A trap from user mode (EL0t), sigma0's, keeps the user's stack pointer
  // in the frame; a kernel-mode trap's is where its frame ends.
  regs.regs.sp = (ts->pstate & 0xf) == 0
    ? ts->usp
    : reinterpret_cast<Mword>(static_cast<Return_frame const *>(ts) + 1);
  regs.regs.pc = ts->pc;
  regs.regs.state = ts->pstate;
  Erx_stop_live live;
  erx_machine_stop_live(&live);
  regs.space_root = live.space_root;
  unsigned ec = ts->esr.ec().get();
  regs.cause = ts->esr.raw();
  regs.addr = stop_fault_addr(ec, ts->pf_address);
  erx_fault_t fault = {};
  fault.cause = uint32_t(ts->esr.raw());
  fault.addr = regs.addr;
  fault.pc = ts->pc;
  erx_stop_trapped(regs, fault, "%s: exception class 0x%02x", what, ec);
}

// The glue's setup, from the boot handoff: the record's form and the build's
// identifier, ERX_BUILD_ID_SIZE bytes, the panic stacks' headers and the
// boot CPU's hardware identifier.
PUBLIC static
void
Erx_machine_stop::boot(bool development, uint8_t const *build_id)
{
  erx_stop_form = development ? ERX_CRASH_FORM_FULL : ERX_CRASH_FORM_BRIEF;
  for (unsigned at = 0; at < ERX_BUILD_ID_SIZE; ++at)
    erx_stop_build_id[at] = build_id[at];
  // Each panic stack's header names its CPU, as Fiasco's Context does, and
  // stays zero otherwise; Fiasco reads a context's header the same way.
  for (unsigned cpu = 0; cpu < Config::Max_num_cpus; ++cpu)
    reinterpret_cast<Context_base *>(erx_panic_stacks[cpu].bytes)
      ->set_current_cpu(Cpu_number(cpu));
  // The boot CPU's identifier, so a stop before its admission finds its
  // number in the table and not through the stack pointer.
  __atomic_store_n(&erx_stop_hwid[cxx::int_value<Cpu_number>(Cpu_number::boot_cpu())],
                   Cpu::mpidr() + 1, __ATOMIC_RELAXED);
}

// The admission (docs/design-debugger.md, "Stopping every CPU"): the last
// step of a CPU's start, with interrupts masked. A CPU that finds the stop
// word set publishes its registers here as `starting` and parks.
PUBLIC static
void
Erx_machine_stop::admit()
{
  // The admission runs with interrupts masked; the boot CPU has unmasked them.
  auto const irqs = Proc::cli_save();
  unsigned const cpu = cxx::int_value<Cpu_number>(current_cpu());
  __atomic_store_n(&erx_stop_hwid[cpu], Cpu::mpidr() + 1, __ATOMIC_RELAXED);
  erx_stop_admission_t admission = erx_machine_stop_admission_begin(cpu);
  uint32_t word = 0;
  for (;;)
    {
      switch (admission.step)
        {
        case ERX_STOP_STEP_SET_BIT:
          __atomic_fetch_or(&erx_stop_admitted, uint64_t{1} << cpu, __ATOMIC_RELAXED);
          break;
        case ERX_STOP_STEP_FENCE:
          __atomic_thread_fence(__ATOMIC_SEQ_CST);
          break;
        case ERX_STOP_STEP_LOAD_WORD:
          word = __atomic_load_n(&erx_debug_anchor.stop, __ATOMIC_ACQUIRE);
          break;
        case ERX_STOP_STEP_RUN:
          Proc::sti_restore(irqs);
          return;
        default:
          {
            static Entry entries[Config::Max_num_cpus];
            Entry *const entry = &entries[cpu];
            entry->cpu = cpu;
            (void)erx_stop_deeper(cpu);
            erx_machine_stop_switch(&entry->regs,
                                    erx_panic_stacks[cpu].bytes + Panic_stack_bytes,
                                    [](void *arg)
                                      {
                                        Entry *const e = static_cast<Entry *>(arg);
                                        erx_stop_publish(e->cpu, ERX_STOP_CPU_STATE_STARTING,
                                                         e->regs, 0);
                                        erx_stop_park();
                                      }, entry);
          }
        }
      admission = erx_machine_stop_admission_next(admission, word);
    }
}

// The stop request, from the debug interrupt's handler: the CPU publishes
// the registers the interrupt interrupted as `stopped` and parks. A request
// that finds no stop word, or no interrupt frame, returns.
PUBLIC static
void
Erx_machine_stop::request()
{
  unsigned const cpu = erx_stop_cpu();
  if (cpu >= Config::Max_num_cpus)
    return;
  uint32_t const word = __atomic_load_n(&erx_debug_anchor.stop, __ATOMIC_ACQUIRE);
  erx_stop_cpu_state_t const state = erx_machine_stop_check(ERX_STOP_AT_REQUEST, word, cpu);
  Return_frame const *frame = erx_irq_frame[cpu];
  // A request outside the interrupt entry has no registers to publish, and
  // `stopped` always carries them: the CPU runs on, and answers the leader's
  // next ask from an interrupt.
  if (!state || !frame)
    return;
  (void)erx_stop_deeper(cpu);
  erx_stop_regs_t regs = {};
  Erx_stop_live live;
  erx_machine_stop_live(&live);
  regs.space_root = live.space_root;
  for (unsigned r = 0; r < 31; ++r)
    regs.regs.gpr[r] = frame->r[r];
  // The interrupt entry does not save the user's stack pointer, which
  // Fiasco keeps in SP_EL0 until a thread switch, so a CPU interrupted in
  // user mode (EL0t) reads it live; the kernel runs on SP_EL1.
  regs.regs.sp = (frame->pstate & 0xf) == 0 ? live.user_sp : erx_irq_sp[cpu];
  regs.regs.pc = frame->pc;
  regs.regs.state = frame->pstate;
  erx_stop_publish(cpu, state, regs, 0);
  erx_stop_park();
}

// Called by the interrupt entry (kern/arm/64/ivt.S) before it dispatches,
// with the entry's frame and the stack pointer the interrupt found, and
// after the dispatch with a null frame, so no later request reads a stale one.
extern "C" void
erx_machine_stop_irq_frame(Return_frame *frame, Mword sp)
{
  unsigned const cpu = cxx::int_value<Cpu_number>(current_cpu());
  if (cpu < Config::Max_num_cpus)
    {
      erx_irq_frame[cpu] = frame;
      erx_irq_sp[cpu] = sp;
    }
}

// The crash core's effects (include/erx/core/effects.h), but for the console
// write, which erx_console_ring.cpp defines beside write_uart, the one glue
// file the dispatch-console-write rule lets provide it. The kernel keeps no
// erXos log, so the log's lock guards nothing here.
extern "C" void erx_effect_log_lock(void) {}
extern "C" void erx_effect_log_unlock(void) {}

extern "C" uint64_t
erx_effect_clock_ns(void)
{
  return erx_stop_clock_ns();
}
