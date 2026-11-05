# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

# The boot information page's reader, and the vector it makes. A seed is a good root
# page with its strings placed by hand, then corruptions of it, so mutations start on
# both sides of every check.
fixed = 360
node = 'system@host'
args = "--\0-boot\0start\0"
env = "A=1\0"
good = "\0".b * fixed
{ 0 => 1, 4 => 1, 8 => 4, 12 => 4, 164 => fixed, 168 => node.size, 172 => fixed + node.size, 176 => args.size,
  180 => fixed + node.size + args.size, 184 => env.size }.each { |offset, value| good[offset, 4] = [value].pack('L<') }
good += node + args + env
corrupt = ->(offset, value) { good.dup.tap { |bytes| bytes[offset, 4] = [value].pack('L<') } }
Erx::PackFuzz.declare_target(
  sources: ['liberx/backend/core/boot_info.c'],
  includes: [*Erx::PackFuzz::INCLUDES, '.'],
  seeds: Erx::PackFuzz.indexed_seeds([good, good[0, 300], corrupt.call(172, 0xffffffff), corrupt.call(176, 3000),
                                      corrupt.call(168, 0), corrupt.call(0, 2), "\0".b])
)
