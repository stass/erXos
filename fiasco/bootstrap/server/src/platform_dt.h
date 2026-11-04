// Modified by erXos: it boots from erXos's boot image (docs/design-stopgap.md, "Boot handoff").
/*
 * Copyright (C) 2021-2025 Kernkonzept GmbH.
 * Author(s): Adam Lackorzynski <adam@l4re.org>
 *
 * License: see LICENSE.spdx (in this directory or the directories above)
 */

#include "dt.h"
#include "platform.h"

template<typename BASE>
class Platform_dt : public BASE
{
public:
  virtual l4_addr_t get_fdt_addr() const = 0;

  void setup_memory_map() override
  {
    dt.check_for_dt();
    dt.setup_memory();
  }

  void after_setup_memory_map() override
  {
    dt.after_setup_memory_map();
  }

  void init_dt() override
  {
    dt.init(get_fdt_addr());
  }

  Dt dt;
};
