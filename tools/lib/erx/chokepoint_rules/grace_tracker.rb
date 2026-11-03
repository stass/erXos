# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

module Erx
  module ChokepointRules
    declare_group(
      rules: [
        Chokepoints::Pending.new(
          name: 'grace-tracker-lock', rule: "only the grace tracker takes the tracker's lock (K13)",
          design: "#{KERNEL}#chokepoint-checks",
          awaits: ['kernel/core/*grace*', 'kernel/core/*tracker*'],
          reason: 'reads relocations of the cores'
        )
      ]
    )
  end
end
