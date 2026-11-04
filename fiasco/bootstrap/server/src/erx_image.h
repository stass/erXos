// Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
// SPDX-License-Identifier: BSD-2-Clause
//
// bootstrap's one erXos function (docs/design-stopgap.md, "Boot handoff").

#pragma once

#include <l4/sys/kip.h>
#include "koptions-def.h"
#include "platform.h"
#include "startup.h"

struct Erx_image_loaded
{
  boot_info_t boot_info;
  l4_kernel_info_t *kip;
  L4_kernel_options::Options *options;
};

// Finds and validates the boot image, places what it holds and fills the
// kernel's handoff record. A refusal prints the reason and never returns: every
// refusal of the image's validity comes before any byte is copied, and one that
// only the copied kernel can show, its views' magic, its options block's version
// or a handoff record that does not fit, comes before it is run.
Erx_image_loaded erx_image_load(Platform_base *plat);
