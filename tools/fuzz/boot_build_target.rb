# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

# The boot information page's builder. A seed is the request tools/fuzz/boot_build_fuzz.c
# reads, then its strings: good ones, then each refusal in turn, so mutations start on both
# sides of every check. The numbers are that request's fixed part, in its order.
limits = ->(reserved) { [1, 2, 3, 4].pack('L<4') + [5, 6].pack('Q<2') + [7, 8, 9, reserved].pack('L<4') + [10, 11].pack('Q<2') }
request = lambda do |strings, flags: 4, page: 4096, reserved: 0|
  [[1, flags, 2, 1000].pack('L<4'), [7, 0x1000, 15].pack('Q<3'), limits.call(reserved),
   [page, *strings.map(&:bytesize)].pack('S<*'), "\0".b * 4, *strings].map(&:b).join
end
node = 'system@host'
args = "--\0-boot\0"
env = "A=1\0B=2"
Erx::PackFuzz.declare_target(
  sources: ['liberx/backend/core/boot_info.c'],
  includes: [*Erx::PackFuzz::INCLUDES, '.'],
  seeds: Erx::PackFuzz.indexed_seeds([request.call([node, args, 'start', env, 'C=3']),
                                      request.call([node, '', '', '', ''], flags: 0),
                                      request.call([node, args, 'start', env, 'C=3'], flags: 8),
                                      request.call([node, args, 'start', env, 'C=3'], reserved: 1),
                                      request.call([node, args, 'start', env, 'C=3'], page: 280),
                                      request.call(['system', args, '', '', '']),
                                      request.call(['a@b@c', args, '', '', '']),
                                      request.call([node, "--\0\0-boot\0", '', '', '']),
                                      request.call([node, '', '', 'noequals', '']),
                                      request.call([node, 'a' * 3000, '', '', '']),
                                      "\0"])
)
