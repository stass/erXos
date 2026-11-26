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
//    admission. A CPU finds its own number by its hardware identifier in
//    that table, so the stop trusts no per-CPU pointer of the failing state.
INTERFACE:

#include <cstdarg>
#include <cstddef>
#include "types.h"

class Return_frame;

class Erx_machine_stop
{
public:
  // A panic, a failed assertion or kdb_ke: cause panic, the call site's
  // registers as the leader's.
  [[noreturn]] static void panic(char const *format, va_list args);
  [[noreturn]] static void stop(char const *format, ...)
    __attribute__((format(printf, 1, 2)));
};

IMPLEMENTATION:

#include <cstdio>
#include "erx/core/crash.h"
#include "erx/core/effects.h"
#include "erx/core/machine_stop.h"
#include "config.h"
#include "context_base.h"
#include "cpu.h"
#include "entry_frame.h"
#include "erx_console_ring.h"
#include "ipi.h"
#include "mem.h"
#include "platform_control.h"
#include "processor.h"
#include "timer.h"

// The registers a stop records for the CPU that runs it, and the routine,
// in kern/arm/64/ivt.S, that saves them at its call site, moves to stack_top
// and calls body(arg) there, never to return.
extern "C" [[noreturn]] void
erx_machine_stop_switch(erx_stop_regs_t *regs, void *stack_top,
                        void (*body)(void *), void *arg);

static_assert(Config::Max_num_cpus <= ERX_CPU_LIMIT,
              "every CPU the kernel can start has a stop slot and a bit");
static_assert(sizeof(Mword) == sizeof(uint64_t), "a register is a slot's word");

namespace {

// Each CPU's panic stack: two pages, which hold the formatted message, the
// crash core's writer and the frame's printer below the leader's own frames.
enum { Panic_stack_bytes = 2 * ERX_PAGE_SIZE, Message_bytes = 512 };

// How long the census waits before it asks a silent CPU again.
static constexpr uint64_t Ask_again_ns = 1000000;

struct alignas(16) Panic_stack { unsigned char bytes[Panic_stack_bytes]; };

// What a stop's entry hands the leader on its panic stack.
struct Entry
{
  unsigned cpu;
  char const *format;
  va_list *args;
  erx_stop_regs_t regs;
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

// This CPU's kernel number: its hardware identifier's entry in the table,
// or, for a CPU not yet admitted, the number Fiasco keeps for it.
static unsigned
erx_stop_cpu()
{
  uint64_t const id = Cpu::mpidr() + 1;
  for (unsigned cpu = 0; cpu < Config::Max_num_cpus; ++cpu)
    if (__atomic_load_n(&erx_stop_hwid[cpu], __ATOMIC_RELAXED) == id)
      return cpu;
  return cxx::int_value<Cpu_number>(current_cpu());
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
    erx_effect_console_write(line, sizeof(line) - 1);
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

static void
erx_stop_entry(erx_crash_cpu_t *entry, erx_stop_cpu_state_t state,
               erx_stop_regs_t const &regs, uint64_t aux)
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
  erx_effect_console_write(prefix, sizeof(prefix) - 1);
  erx_effect_console_write(line, used + 1);
}

// The report's first part (docs/design-debugger.md, "The stop", step 6): the
// record's own fields as text for the person at the console. The message in
// every form, any control byte in it shown as '?'; in the full form the
// leader's registers and frames; and one line for each CPU with its state,
// and in the full form where it was.
static void
erx_stop_report(erx_crash_input_t const &input, erx_regs_t const &regs,
                erx_stop_leader_t const &leader)
{
  using Ull = unsigned long long;
  if (!leader.complete)
    erx_stop_say("the census is incomplete: a CPU marked unanswered did not stop");
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
  erx_stop_leader_t const leader = erx_stop_census(cpu);
  // The message is formatted once every CPU is asked, so an argument that
  // faults is a nested stop after the census, not before it.
  int const length = vsnprintf(erx_stop_message, sizeof(erx_stop_message),
                               entry->format, *entry->args);
  Erx_console_ring::close();

  static erx_crash_cpu_t cpus[ERX_CRASH_CPUS];
  uint32_t const ncpus = erx_stop_ncpus(cpu);
  for (unsigned other = 0; other < ncpus && other < ERX_CRASH_CPUS; ++other)
    {
      erx_machine_stop_slot_t const *slot = &erx_stop_slots[other];
      erx_stop_cpu_state_t const published = __atomic_load_n(&slot->state, __ATOMIC_ACQUIRE);
      erx_stop_cpu_state_t const state = erx_machine_stop_final(&leader, other, published);
      if (other == cpu)
        erx_stop_entry(&cpus[other], state, regs, 0);
      else
        erx_stop_entry(&cpus[other], state, slot->regs, slot->aux);
    }

  static uint64_t frames[ERX_CRASH_FRAMES];
  erx_crash_input_t input = {};
  input.form = erx_stop_form;
  input.cause = ERX_CRASH_CAUSE_PANIC;
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
  erx_stop_report(input, regs.regs, leader);
  erx_crash_frame_write(erx_crash_buffer, ERX_CRASH_END_FAULT);
  erx_stop_end(cpu);
}

IMPLEMENT
void
Erx_machine_stop::stop(char const *format, ...)
{
  va_list args;
  va_start(args, format);
  panic(format, args);
}

static void
erx_stop_nested_line()
{
  static char const line[] = "erx: nested stop\n";
  erx_effect_console_write(line, sizeof(line) - 1);
}

IMPLEMENT
void
Erx_machine_stop::panic(char const *format, va_list args)
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
  va_list copy;
  va_copy(copy, args);
  Entry *const entry = &entries[cpu];
  entry->cpu = cpu;
  entry->format = format;
  entry->args = &copy;
  switch (erx_machine_stop_claim(observed, cpu, depth))
    {
    case ERX_STOP_LEAD:
      erx_machine_stop_switch(&entry->regs, erx_panic_stacks[cpu].bytes + Panic_stack_bytes,
                              erx_stop_lead, entry);
    case ERX_STOP_FOLLOW:
      erx_machine_stop_switch(&entry->regs, erx_panic_stacks[cpu].bytes + Panic_stack_bytes,
                              [](void *arg)
                                {
                                  Entry *const e = static_cast<Entry *>(arg);
                                  erx_stop_publish(e->cpu, ERX_STOP_CPU_STATE_CONCURRENT,
                                                   e->regs, 0);
                                  erx_stop_park();
                                }, entry);
    case ERX_STOP_NESTED:
      erx_stop_nested_line();
      erx_stop_end(cpu);
    case ERX_STOP_NESTED_SILENT:
      erx_stop_end(cpu, false);
    case ERX_STOP_FOLLOW_SILENT:
    default:
      erx_stop_park();
    }
}

// The handoff's facts the record carries: its form and the build's identifier,
// ERX_BUILD_ID_SIZE bytes.
PUBLIC static
void
Erx_machine_stop::boot(bool development, uint8_t const *build_id)
{
  erx_stop_form = development ? ERX_CRASH_FORM_FULL : ERX_CRASH_FORM_BRIEF;
  for (unsigned at = 0; at < ERX_BUILD_ID_SIZE; ++at)
    erx_stop_build_id[at] = build_id[at];
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
// that finds no stop word returns.
PUBLIC static
void
Erx_machine_stop::request()
{
  unsigned const cpu = erx_stop_cpu();
  if (cpu >= Config::Max_num_cpus)
    return;
  uint32_t const word = __atomic_load_n(&erx_debug_anchor.stop, __ATOMIC_ACQUIRE);
  erx_stop_cpu_state_t const state = erx_machine_stop_check(ERX_STOP_AT_REQUEST, word, cpu);
  if (!state)
    return;
  (void)erx_stop_deeper(cpu);
  Return_frame const *frame = erx_irq_frame[cpu];
  erx_stop_regs_t regs = {};
  Mword space_root;
  asm volatile("mrs %0, TTBR0_EL1" : "=r"(space_root));
  regs.space_root = space_root;
  if (frame)
    {
      for (unsigned r = 0; r < 31; ++r)
        regs.regs.gpr[r] = frame->r[r];
      // The interrupt entry does not save the user's stack pointer, which
      // Fiasco keeps in SP_EL0 until a thread switch, so a CPU interrupted in
      // user mode (EL0t) reads it live; the kernel runs on SP_EL1.
      Mword user_sp;
      asm volatile("mrs %0, SP_EL0" : "=r"(user_sp));
      regs.regs.sp = (frame->pstate & 0xf) == 0 ? user_sp : erx_irq_sp[cpu];
      regs.regs.pc = frame->pc;
      regs.regs.state = frame->pstate;
    }
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

// The crash core's effects (include/erx/core/effects.h). The kernel keeps no
// erXos log, so the log's lock guards nothing here.
extern "C" void erx_effect_log_lock(void) {}
extern "C" void erx_effect_log_unlock(void) {}

extern "C" uint64_t
erx_effect_clock_ns(void)
{
  return erx_stop_clock_ns();
}

// Every line of the stop's, the crash core's frame among them, takes the
// UART's polled write (Erx_console_ring::write_uart).
extern "C" void
erx_effect_console_write(char const *line, size_t length)
{
  Erx_console_ring::write_uart(line, length);
}
