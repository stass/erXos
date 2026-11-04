# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

# The root service's decoder. An input is the gate label (eight bytes), the tag's
# label (eight), the tag's word count, the count of live tasks, then message words,
# in the order tools/fuzz/service_wire_fuzz.c reads them.
message = ->(label, tag, words, tasks, *mr) { [label, tag, words, tasks, *mr].pack('Qq<CCQ*') }
Erx::PackFuzz.declare_target(
  sources: ['liberx/backend/fiasco/service_wire.c'],
  includes: [*Erx::PackFuzz::INCLUDES, '.'],
  seeds: Erx::PackFuzz.indexed_seeds(
    [message.call(0, 3, 2, 1, 0, 1),
     message.call(4, 3, 2, 1, 0, 1),
     message.call(3, -2, 2, 1, 0x1000, 0x44000000),
     message.call(0, -5, 0, 1),
     message.call(0, -5, 40, 1),
     message.call(0, -2, 0, 1),
     message.call(0, 2, 6, 1, 0, 0, 0, 0, 0, 5),
     message.call(0, 3, 2, 1, 128, 0),
     message.call(0, 200, 2, 1),
     message.call(0, 1, 1, 1, 0)]
  )
)
