/*
 * Copyright (C) 2026 Kernkonzept GmbH.
 * Author(s): Georg Kotheimer <georg.kotheimer@kernkonzept.com>
 *
 * License: see LICENSE.spdx (in this directory or the directories above)
 */

#pragma once

#include <l4/sys/compiler.h>

L4_BEGIN_DECLS

extern unsigned long *
__pthread_alloc_pi_mutex_kumem_slot(void);

extern void
__pthread_free_pi_mutex_kumem_slot(unsigned long *);

L4_END_DECLS
