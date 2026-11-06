// Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
// SPDX-License-Identifier: BSD-2-Clause
//
// The kernel's side of bootstrap's handoff record (docs/design-stopgap.md, "The
// handoff record"): it accepts the record through the C17 core, prints the
// banner's line for the boot image, and checks that a bootloader descriptor
// covers the archive. A kernel started without bootstrap's validator has a
// zero record and stops here, before it starts anything.
INTERFACE:

#include "initcalls.h"

class Erx_handoff
{
};

IMPLEMENTATION:

#include <cstdio>
#include "erx/core/boot_handoff.h"
#include "kip.h"
#include "koptions.h"
#include "panic.h"

static_assert(sizeof(Koptions::Options::erx_handoff) == ERX_BOOT_HANDOFF_RECORD_SIZE,
              "the options block embeds the whole handoff record");

static FIASCO_INIT
erx_boot_handoff_view_t
erx_handoff_accept()
{
  erx_boot_handoff_view_t view;
  char const *reason = erx_boot_handoff_accept(Koptions::o()->erx_handoff,
                                               sizeof(Koptions::o()->erx_handoff),
                                               &view);
  if (reason)
    panic("erx: boot handoff refused: %s", reason);
  return view;
}

PUBLIC static FIASCO_INIT
void
Erx_handoff::banner()
{
  erx_boot_handoff_view_t view = erx_handoff_accept();

  if (view.development)
    printf("development build: trusted code only\n");
  if (view.test_code)
    printf("test image: carries test code\n");
  printf("erx: boot image build ");
  for (unsigned char byte : view.build_id)
    printf("%02x", byte);
  printf(" index ");
  for (unsigned char byte : view.index_hash)
    printf("%02x", byte);
  printf(" flags 0x%x archive 0x%llx+0x%llx bootargs %u\n", view.flags,
         static_cast<unsigned long long>(view.image.start),
         static_cast<unsigned long long>(view.image.size), view.bootargs_len);
}

// The archive's bytes stay reserved only while a descriptor says so.
PUBLIC static FIASCO_INIT
void
Erx_handoff::check_descriptors()
{
  erx_boot_handoff_view_t view = erx_handoff_accept();

  for (auto const &md: Kip::k()->mem_descs_a())
    {
      if (md.type() != Mem_desc::Bootloader)
        continue;
      erx_boot_range_t range = { md.start(), md.end() - md.start() + 1 };
      if (erx_boot_handoff_covered(&view, &range, 1))
        return;
    }
  panic("erx: boot handoff refused: no bootloader descriptor covers the archive");
}
