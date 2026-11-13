# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

# GENET's register ring core against a hostile controller, every plan through the
# check. Scripts in tools/fuzz/device_genet_fuzz.c's format: posts and their
# completion; received frames honest, flagged, too long and with a high length bit; a producer index past
# the queue's size; a consumer index past what is in flight; and a reset after a
# broken queue.
setup = [2047].pack('v')
posts = ([0, 100].pack('Cv') * 3)
frame = ->(length, flags) { [(length << 16) | flags].pack('V') }
Erx::PackFuzz.declare_target(
  sources: %w[otp/erts/emulator/nifs/erxos/erx_device_genet.c otp/erts/emulator/nifs/erxos/erx_device_dma.c
              otp/erts/emulator/nifs/erxos/erx_device_core.c],
  includes: [*Erx::PackFuzz::INCLUDES, '.', 'build/gen', 'build/gen/include', 'otp/erts/emulator/nifs/erxos'],
  seeds: {
    'transmit' => setup + posts + [1, 3].pack('CV'),
    'receive' => setup + [2, 2].pack('CV') + frame.(64, 0x6000) + frame.(1500, 0x6002),
    'long' => setup + [2, 1].pack('CV') + frame.(2049, 0x6000),
    'high-bit' => setup + [2, 1].pack('CV') + frame.(0x100a, 0x6000),
    'liar-producer' => setup + [2, 257].pack('CV'),
    'liar-consumer' => setup + posts + [1, 4].pack('CV'),
    'reset' => setup + [2, 257].pack('CV') + [3].pack('C') + [2, 1].pack('CV') + frame.(10, 0x6000)
  }
)
