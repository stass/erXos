// Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
// SPDX-License-Identifier: BSD-2-Clause
//
// The one-shot timer's compare value (docs/design-fiasco.md, "The release's
// Fiasco build", "The timer's compare value"): the first count at which the
// kernel's clock reads a wakeup, which the C17 core derives from the clock's
// own scaler, so the timeout that programmed the compare has expired by the
// clock when its interrupt arrives.
INTERFACE:

#include "scaler_shift.h"
#include "types.h"

class Erx_clock
{
};

IMPLEMENTATION:

#include "erx/core/clock_inverse.h"

PUBLIC static
Unsigned64
Erx_clock::first_count(Scaler_shift const &clock, Unsigned64 us)
{
  return erx_clock_first_count(us, clock.scaler, clock.shift);
}
