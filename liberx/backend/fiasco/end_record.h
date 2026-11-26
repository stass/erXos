/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

#ifndef ERX_FIASCO_END_RECORD_H
#define ERX_FIASCO_END_RECORD_H

#include <stdbool.h>
#include <stdint.h>

#include "erx/core/crash.h"

/*
 * The crash record a root end writes (docs/design-debugger.md, "The
 * record's trace tail", "Who sees it"): in the boot image's form, as the kernel's
 * own stop writes its record, so a release build's root prints the brief form.
 * Its trace tail comes from the kernel's rings once the trace window maps; the
 * crash core reads them only for the full form. No l4 call, so the host tests it.
 */

/* The boot image's kind, from its handoff; until it is told, every record is brief. */
void		erx_fiasco_end_boot(bool development);
/*
 * Whether the kernel's rings record in this boot (erx_fiasco_trace_boot). Until it is
 * told, every record sets trace_none: a root that has not decided cannot say they recorded.
 */
void		erx_fiasco_end_trace(bool on);
/*
 * The kernel's rings, count of them, at rings: the trace window, once it maps. A
 * boot whose window did not map never calls it, and its records carry no tail.
 */
void		erx_fiasco_end_trace_rings(const void *rings, uint32_t count);
/*
 * Writes into record, with scratch, the record input asks for in the boot image's
 * form, whatever form input names; with the kernel's rings for its tail only when
 * trace is true, as a task's fault the machine survives passes false. Returns the
 * record's length (erx_crash_record_write).
 */
uint32_t	erx_fiasco_end_record_write(erx_crash_input_t input, bool trace, void *record,
		    void *scratch);

#endif /* ERX_FIASCO_END_RECORD_H */
