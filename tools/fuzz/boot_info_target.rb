# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

# The boot information page's reader, and the vector it makes. A seed is a good root
# page with its strings placed by hand, then corruptions of it, so mutations start on
# both sides of every check. The offsets are erx_boot_info's in abi/erx_abi.txt, and
# fixed is ERX_BOOT_INFO_SIZE with the root extension's 88 bytes.
fixed = 288 + 88
at = { version: 0, abi_version: 4, domain_id: 8, flags: 12, domain_pid_number: 112 + 48, node_off: 180,
       node_len: 184, args_off: 188, args_len: 192, env_off: 196, env_len: 200 }.freeze
node = 'system@host'
env = "A=1\0"
page = lambda do |args|
  header = "\0".b * fixed
  { version: 1, abi_version: 1, domain_id: 4, flags: 4, node_off: fixed, node_len: node.size,
    args_off: fixed + node.size, args_len: args.size, env_off: fixed + node.size + args.size,
    env_len: env.size }.each { |field, value| header[at.fetch(field), 4] = [value].pack('L<') }
  header + node + args + env
end
good = page.call("--\0-boot\0start\0")
# A display domain's page, its framebuffer record among init's arguments.
framebuffer = page.call("--\0-boot\0start\0-erx\0framebuffer\0" "7\0" "64\0" "8294400\0" "1920\0" "1080\0" "7680\0x8r8g8b8\0")
corrupt = ->(field, value) { good.dup.tap { |bytes| bytes[at.fetch(field), 4] = [value].pack('L<') } }
Erx::PackFuzz.declare_target(
  sources: ['liberx/backend/core/boot_info.c'],
  includes: [*Erx::PackFuzz::INCLUDES, '.'],
  seeds: Erx::PackFuzz.indexed_seeds([good, framebuffer, good[0, 300], corrupt.call(:args_off, 0xffffffff),
                                      corrupt.call(:args_len, 3000), corrupt.call(:node_len, 0),
                                      corrupt.call(:version, 2), corrupt.call(:domain_pid_number, 1), "\0".b])
)
