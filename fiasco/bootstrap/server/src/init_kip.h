// Modified by erXos: it boots from erXos's boot image (docs/design-stopgap.md, "Boot handoff").
/*
 * Copyright (C) 2008-2009 Technische Universität Dresden.
 * Copyright (C) 2023-2025 Kernkonzept GmbH.
 * Author(s): Adam Lackorzynski <adam@os.inf.tu-dresden.de>
 *            Alexander Warg <warg@os.inf.tu-dresden.de>
 *            Frank Mehnert <fm3@os.inf.tu-dresden.de>
 *
 * License: see LICENSE.spdx (in this directory or the directories above)
 */

#pragma once

#include <l4/sys/kip.h>

#include "startup.h"
#include "region.h"

void init_kip_infos(l4_kernel_info_t *l4i, boot_info_t *bi);

void init_kip_md(l4_kernel_info_t *l4i, Region_list *ram, Region_list *regions);
