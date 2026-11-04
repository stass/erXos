// Modified by erXos: it boots from erXos's boot image (docs/design-stopgap.md, "Boot handoff").
/*
 * Copyright (C) 2018-2025 Kernkonzept GmbH.
 * Author(s): Sarah Hoffmann <sarah.hoffmann@kernkonzept.com>
 *
 * License: see LICENSE.spdx (in this directory or the directories above)
 */

#include <l4/drivers/uart_pl011.h>
#include "support.h"
#include "startup.h"
#include "panic.h"
#include "platform_dt-arm.h"

extern char _start;

namespace {
class Platform_arm_virt : public Platform_dt_arm
{
  bool probe() override { return true; }

  l4_addr_t get_fdt_addr() const override
  {
    // The boot protocol's argument register, and nothing else: only QEMU's ELF
    // path fills the RAM base, and no probe may read memory it did not fill.
    return Platform_dt_arm::get_fdt_addr();
  }

  void init() override
  {
    dt.check_for_dt();
    dt.get_stdout_uart("arm,pl011", &parse_gic_irq, &kuart, &kuart_flags);

    static L4::Io_register_block_mmio r(kuart.base_address);
    static L4::Uart_pl011 _uart(kuart.base_baud);
    _uart.startup(&r);
    set_stdio_uart(&_uart);
  }

  void after_setup_memory_map() override
  {
    dt.after_setup_memory_map();
  }

  void late_setup(l4_kernel_info_t *kip) override
  {
    bool have_smmuv3 = dt.node_by_compatible("arm,smmu-v3").is_valid();
    bool kernel_uses_smmuv3 = l4_kip_kernel_has_feature(kip, "arm,smmu-v3");

    if (kernel_uses_smmuv3 && !have_smmuv3)
      panic("Microkernel uses SMMU-v3 but QEMU missing '-M virt,iommu=smmuv3'");

    set_dtb_in_kip(kip);
  }

  void reboot() override
  {
    reboot_psci();
  }
};
}

REGISTER_PLATFORM(Platform_arm_virt);
