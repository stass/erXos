/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

/* The domain library's install funnel (liberx/system/dom_install.h). */

#include <stdbool.h>
#include <stdint.h>

#include "erx/abi.h"
#include "erx/dom.h"
#include "liberx/backend/api.h"
#include "liberx/system/dom_install.h"

erx_status_t
erx_dom_install(const erx_dom_step_t *step, uint64_t object, uint64_t recipient, uint64_t *value)
{
	erx_utcb_t *const utcb = erx_utcb_self();
	uint64_t desc = 0, passed = ERX_CAP_NULL;
	erx_status_t status;

	if (step->kind != ERX_DOM_STEP_INSTALL)
		return (ERX_EINVAL);
	(void)erx_msg_item_desc_rights_set(&desc, step->rights);
	(void)erx_msg_item_desc_move_set(&desc, false);
	(void)erx_utcb_mr_store(utcb, 0, desc);
	(void)erx_utcb_mr_store(utcb, 1, object);
	status = erx_cap_pass(ERX_CAP_SELF, recipient, 1);
	if (status != ERX_OK)
		return (status);
	(void)erx_utcb_mr_load(utcb, 1, &passed);
	*value = passed;
	return (ERX_OK);
}
