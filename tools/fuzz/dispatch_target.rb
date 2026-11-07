# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

# System-call argument decoding through the one funnel. An input is the call
# number and six argument registers, then the bytes of the message words;
# tools/fuzz/dispatch_fuzz.c runs the call and checks the result words and the
# console. Seeds: a good line, the longest, each refused length and a number
# with no call, and message words of what an attacker would send to a terminal.
frame = ->(number, first, text = '') { [number, first, 0, 0, 0, 0, 0].pack('Q<7') + text.b }

Erx::PackFuzz.declare_target(
  sources: %w[kernel/core/admit.c kernel/core/debug_log.c kernel/core/dispatch.c kernel/core/log.c
              build/gen/kernel/generated/abi_decode.c build/gen/kernel/generated/abi_run.c],
  seeds: {
    'good' => frame.call(1, 5, 'hello'),
    'empty' => frame.call(1, 0),
    'full' => frame.call(1, 504, "\x01" * 504),
    'over' => frame.call(1, 505),
    'high-bits' => frame.call(1, 0x100000005),
    'number-zero' => frame.call(0, 0),
    'number-max' => frame.call(0xFFFFFFFFFFFFFFFF, 0),
    'terminal' => frame.call(1, 32, "\e]52;c;aGk=\e\\\n\xE2\x80\xAEevil\xC0\x80\x9B31m\xFF\xFE")
  }
)
