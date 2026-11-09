/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

#ifndef ERX_DOM_INSTALL_H
#define ERX_DOM_INSTALL_H

#include <stdint.h>

#include "erx/abi.h"
#include "erx/cdefs.h"
#include "erx/dom.h"

/*
 * The domain library's one install (docs/design-system.md, A7, "The grant
 * table"): a copy of object, a handle in the system domain's own table, with
 * its rights shrunk to the step's, passed into recipient, the space the plan
 * names for the step's row of erx_dom_grants, for a creation and for a
 * connection alike. The plan's check (erx_dom_plan_check, or
 * erx_dom_link_check for a connection) found that row and recipient
 * before anything was applied. *value is the copy's value
 * in the recipient's table, written only on ERX_OK. The library never moves
 * a capability and never passes out of another domain's table, so this file
 * holds its only erx_cap_pass, which tools/lib/erx/chokepoint_rules/cap.rb
 * keeps so (dom-install-funnel).
 */
erx_status_t	erx_dom_install(const erx_dom_step_t *step, uint64_t object,
		    uint64_t recipient, uint64_t *value) ERX_WARN_UNUSED_RESULT;

#endif /* ERX_DOM_INSTALL_H */
