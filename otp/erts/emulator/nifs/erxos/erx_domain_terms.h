/*
 * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
 * SPDX-License-Identifier: BSD-2-Clause
 */

/*
 * The domain library's view of the manifest's services, facet rows and drives as
 * the terms erx_domain_lib:configured/0 returns (erx_domain_lib_nif.c).
 * Pure: it reads only the view it is given, so its host test
 * (test/host/facet_parameters_test.rb) builds it with the boot view alone.
 */

#ifndef ERX_DOMAIN_TERMS_H
#define ERX_DOMAIN_TERMS_H

#include <stdbool.h>

#include "erl_nif.h"

#include "erx/dom.h"

bool	erx_domain_served_terms(ErlNifEnv *, const erx_dom_view_t *, ERL_NIF_TERM *services,
	    ERL_NIF_TERM *grants);
ERL_NIF_TERM erx_domain_drives_term(ErlNifEnv *, const erx_dom_view_t *, uint32_t row);

#endif /* ERX_DOMAIN_TERMS_H */
