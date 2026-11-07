# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

# The trace ring's reader over a ring the input writes (tools/fuzz/trace_ring_fuzz.c):
# head, cursor and max, then slots as an index, a sequence and a field word. Seeds: a
# whole record read back, the present cursor, a lapped reader, a torn count, a cursor
# past the head, max out of range and an exhausted head.
def ring_input(head:, cursor:, max:, slots: [])
  [head, cursor, max].pack('Q<Q<S<') + slots.map { |index, seq, word| [index, seq, word].pack('S<Q<Q<') }.join.b
end

exhausted = (0xffff_ffff_ffff_ffff - 3) / 2 + 1

Erx::PackFuzz.declare_target(
  sources: ['liberx/backend/core/trace_ring.c'],
  includes: [*Erx::PackFuzz::INCLUDES, '.'],
  seeds: {
    'whole' => ring_input(head: 2, cursor: 0, max: 4, slots: [[0, 2, 7], [1, 4, 9]]),
    'present' => ring_input(head: 9, cursor: 0xffff_ffff_ffff_ffff, max: 1),
    'lapped' => ring_input(head: 5000, cursor: 3, max: 512, slots: [[904, 2 * 4904 + 2, 1]]),
    'torn' => ring_input(head: 3, cursor: 0, max: 3, slots: [[0, 1, 0], [1, 4, 0], [2, 9, 0]]),
    'past-head' => ring_input(head: 3, cursor: 4, max: 1),
    'max-zero' => ring_input(head: 3, cursor: 0, max: 0),
    'max-over' => ring_input(head: 3, cursor: 0, max: 513),
    'exhausted' => ring_input(head: exhausted, cursor: exhausted, max: 1),
    'beyond-exhausted' => ring_input(head: 0xffff_ffff_ffff_fff0, cursor: exhausted - 2, max: 8)
  }
)
