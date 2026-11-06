# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

# The device queue's core against a hostile device. Scripts in
# tools/fuzz/device_queue_fuzz.c's format: a block request's chain of a
# header, data and a status byte, completed whole and short; a used index, a
# used id and a used length each beyond what was posted; a queue too small
# for a second chain; a pool ending at the top of the address space; and a reset
# after a broken queue.
segment = ->(offset, length, writes) { [offset, length, writes].pack('vvC') }
request = [0, 3].pack('CC') + segment.(0, 16, 0) + segment.(16, 512, 1) + segment.(528, 1, 1)
honest = [2, 1].pack('CC')
# A queue of 8 entries with buffers of 1024 bytes low in the address space.
setup = "\x03".b + [1023, 0].pack('vC')
Erx::PackFuzz.declare_target(
  sources: ['otp/erts/emulator/nifs/erxos/erx_device_queue.c'],
  includes: [*Erx::PackFuzz::INCLUDES, 'otp/erts/emulator/nifs/erxos'],
  seeds: {
    'request' => setup + request + honest + [4, 0, 513].pack('CCV'),
    'short' => setup + request + honest + [4, 0, 100].pack('CCV'),
    'liar-index' => setup + request + [1, 0xffff].pack('Cv') + request,
    'liar-id' => setup + request + honest + [3, 9, 1].pack('CVV') + request,
    'liar-length' => setup + request + honest + [4, 0, 0x80000258].pack('CCV'),
    'full' => "\x00".b + [1023, 0].pack('vC') + request + [0, 1].pack('CC') + segment.(0, 8, 1),
    'top' => "\x03".b + [63, 1].pack('vC') + [0, 1].pack('CC') + segment.(0, 64, 1),
    'reset' => setup + request + [1, 7].pack('Cv') + [5].pack('C') + request + honest + [4, 0, 513].pack('CCV')
  }
)
