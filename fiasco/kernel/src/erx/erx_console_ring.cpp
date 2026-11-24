// Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
// SPDX-License-Identifier: BSD-2-Clause
//
// The ring console (docs/design-fiasco.md, "The kernel's lines"): the one
// console in front of the UART's, through which every line the kernel
// prints passes, and the route the C17 core keeps. Under uart and closed a
// write goes to the UART; under ring it goes to the core's ring, which the
// root drains with Vlog's take. The close writes the ring out and leaves
// the UART to the kernel for good; every stop's report begins with it. The
// printf lock serializes the write, the take and the close across CPUs.
INTERFACE:

#include "console.h"
#include "initcalls.h"
#include "types.h"

// The console the multiplexer holds in the UART console's place, with the
// UART console's attributes and input.
class Erx_ring_console : public Console
{
private:
  Console *const _o;
};

class Erx_console_ring
{
public:
  // What a Vlog operation number names: the ring console's take or close,
  // or another operation, not the ring console's.
  enum class Op { Other, Take, Close };

  // The words of a take's reply, which Vlog copies into its message words.
  enum { Reply_words = 63 };
};

IMPLEMENTATION:

#include <libc_backend.h>
#include "erx/core/console_ring.h"
#include "global_data.h"
#include "vlog.h"

static_assert(Erx_console_ring::Reply_words == ERX_CONSOLE_RING_REPLY_WORDS,
              "a take's reply is every message word");
static_assert(ERX_CONSOLE_RING_OP_TAKE > Mword(Vlog::Op::Get_attr)
              && ERX_CONSOLE_RING_OP_CLOSE > Mword(Vlog::Op::Get_attr),
              "the ring console's operations follow Fiasco's own");
static_assert(sizeof(Mword) == sizeof(uint64_t),
              "a reply word is a message word");

// The ring and the UART console it stands in front of; all zeros is the
// route uart and an empty ring.
static DEFINE_GLOBAL_CONSTINIT Global_data<erx_console_ring_t> _ring{erx_console_ring_t{}};
static DEFINE_GLOBAL_CONSTINIT Global_data<Console *> _uart;
static DEFINE_GLOBAL Global_data<Static_object<Erx_ring_console>> _rcon;

// Holds the printf lock for its scope, as every write already does.
class Erx_printf_locked
{
public:
  Erx_printf_locked() : _state(__libc_backend_printf_lock()) {}
  ~Erx_printf_locked() { __libc_backend_printf_unlock(_state); }
  Erx_printf_locked(Erx_printf_locked const &) = delete;
  Erx_printf_locked &operator = (Erx_printf_locked const &) = delete;

private:
  unsigned _state;
};

PUBLIC inline explicit
Erx_ring_console::Erx_ring_console(Console *uart)
: Console(ENABLED), _o(uart)
{
  if (uart->failed())
    fail();
}

// Every byte the kernel prints: the UART's under uart and closed, the
// ring's under ring.
PUBLIC
int
Erx_ring_console::write(char const *str, size_t len) override
{
  if (erx_console_ring_write(&_ring, str, len) && (_o->state() & OUTENABLED))
    return _o->write(str, len);
  return len;
}

// The multiplexer sets a state by the attributes, which are the UART
// console's, so the state goes to it too: the debugger's FILTER_ENABLED
// reaches the filter console.
PUBLIC
void
Erx_ring_console::state(Mword new_state) override
{
  Console::state(new_state);
  _o->state(new_state);
}

PUBLIC
int
Erx_ring_console::getchar(bool blocking = true) override
{ return _o->getchar(blocking); }

PUBLIC
Mword
Erx_ring_console::get_attributes() const override
{ return _o->get_attributes(); }

// The console kernel_uart.cpp registers in the UART console's place.
PUBLIC static FIASCO_INIT
Console *
Erx_console_ring::wrap(Console *uart)
{
  _uart = uart;
  _rcon.construct(uart);
  return _rcon;
}

// The operation numbers are the core's alone, so Vlog names none.
PUBLIC static
Erx_console_ring::Op
Erx_console_ring::op(Mword number)
{
  switch (number)
    {
    case ERX_CONSOLE_RING_OP_TAKE:
      return Op::Take;
    case ERX_CONSOLE_RING_OP_CLOSE:
      return Op::Close;
    default:
      return Op::Other;
    }
}

// The take: the reply's words into words, which the caller owns, and how
// many there are.
PUBLIC static
unsigned
Erx_console_ring::take(Mword (&words)[Reply_words])
{
  erx_console_reply_words_t reply;

  {
    Erx_printf_locked locked;
    erx_console_ring_take(&_ring, &reply);
  }
  for (unsigned at = 0; at < reply.count; at++)
    words[at] = reply.words[at];
  return reply.count;
}

// The close, and the head of every stop's report: the first close
// writes the ring out to the UART, under the lock, before anything else
// the kernel prints.
PUBLIC static
void
Erx_console_ring::close()
{
  erx_console_drain_t piece;
  size_t length;
  Erx_printf_locked locked;
  Console *const uart = _uart;

  if (!erx_console_ring_close(&_ring))
    return;
  // An empty ring drains nothing, so a close before wrap writes nothing.
  while ((length = erx_console_ring_drain(&_ring, &piece)) != 0)
    if (uart->state() & Console::OUTENABLED)
      uart->write(piece.bytes, length);
}

// --------------------------------------------------------------------------
IMPLEMENTATION [input]:

PUBLIC
int
Erx_ring_console::char_avail() const override
{ return _o->char_avail(); }
