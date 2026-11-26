# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

# map_trace's decoding (tools/fuzz/trace_window_fuzz.c): flags (mempage, mapped), the word
# count, the flexpage's base and order, the user space's last address and the rings' pages.
# Seeds: the root's own call, a second call, a window too small, one past user space, one
# misaligned, a call of three words and an order of 64.
def window_input(words: 2, flags: 1, base: 0xd_0000_0000, order: 25, user_last: (1 << 39) - 1, pages: 513)
  [flags, words, base, order, user_last, pages].pack('CL<Q<CQ<L<')
end

Erx::PackFuzz.declare_target(
  sources: ['kernel/core/trace_window.c'],
  includes: [*Erx::PackFuzz::INCLUDES, '.'],
  seeds: {
    'root' => window_input,
    'second' => window_input(flags: 3),
    'too-small' => window_input(base: 0x20_0000, order: 21),
    'past-user' => window_input(base: 1 << 39),
    'misaligned' => window_input(base: 0xd_0000_1000),
    'three-words' => window_input(words: 3),
    'order-64' => window_input(base: 0, order: 64)
  }
)
