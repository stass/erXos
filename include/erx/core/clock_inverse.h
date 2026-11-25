/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

#ifndef ERX_CORE_CLOCK_INVERSE_H
#define ERX_CORE_CLOCK_INVERSE_H

/*
 * The one-shot timer's compare value on Fiasco (docs/design-fiasco.md, "The
 * release's Fiasco build", "The timer's compare value"). Fiasco's clock reads
 * (count * scaler) >> (32 - shift) microseconds of the counter's count, with a
 * scaler rounded down, so it lags the counter by up to a part in the
 * scaler (in about 2^27 at 24 MHz), which adds up as the count grows. A timeout due at a microsecond W expires once the clock
 * reads W, so the compare value that wakes it must be a count at which the
 * clock reads W: the inverse of the clock's own arithmetic, not a separate
 * conversion of W to counts that can land where the clock still reads W - 1.
 *
 * This header is C and C++: the glue in fiasco/kernel/src/erx includes it.
 */

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/*
 * The least count at which (count * scaler) >> (32 - shift) reaches us, for a
 * nonzero scaler and a shift below 32, as Scaler_shift::init gives; UINT64_MAX
 * where that count is past the counter's 64 bits, a compare value never reached.
 */
uint64_t	erx_clock_first_count(uint64_t us, uint32_t scaler, uint32_t shift);

#ifdef __cplusplus
}
#endif

#endif /* ERX_CORE_CLOCK_INVERSE_H */
