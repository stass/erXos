# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

# The mapping-record core, fed the addresses, sizes, flags, protections,
# offsets and allocation failures a domain's range calls control. The first
# byte picks the user range; then each command byte is 0 insert, 1 release, 2 a
# bounded call, 3 a deleted object and 4 the edge rule. The helpers below lay
# their fields out in the order tools/fuzz/map_fuzz.c decodes them, each ending
# with the byte that says how its allocation goes, 0 for it succeeding; a kind
# byte and an operation byte are one less than the value they name.
reserved_kind = 0
private_kind = 1
object_kind = 2
insert = lambda do |page, kind, object: nil, prot: 0, ceiling: 3|
  [0, 0, 0, page, 0x80, 0x1f, 1, 0, kind, 0, 0, 0, prot, ceiling, 0, *object, 0].pack('C*')
end
call = ->(operation, page, size, prot: 0) { [2, operation, 1, prot, 0, page, 0x80, size, 0].pack('C*') }
window = [0].pack('C')
reserve = insert.call(0x10, reserved_kind)
mapped = insert.call(0x60, object_kind, object: 1, prot: 1)
commit = call.call(0, 0x10, 0x1f)
decommit = call.call(1, 0x12, 1)
protect = call.call(2, 0x10, 0x1f, prot: 1)
release = [1, 0, 0x14, 0, 1, 0].pack('C*')
deleted = [3, 0x60].pack('C*')
edges = [4, 0, 0x20, 0x80, 0x20, 0, 3].pack('C*')
top = [0, 0, 0xff].pack('C*') + [0xfffffffffffff000].pack('Q>') + [0xff].pack('C') + [0x1000].pack('Q>')
image = insert.call(0x40, private_kind, object: 2, prot: 3)
Erx::PackFuzz.declare_target(
  sources: ['kernel/core/map.c'],
  seeds: Erx::PackFuzz.indexed_seeds(
    [window,
     "#{window}#{reserve}#{commit}".b,
     "#{window}#{reserve}#{mapped}#{image}#{commit}#{protect}#{deleted}#{decommit}#{release}".b,
     # A range and a base at the top of the 52-bit space.
     "\x01#{top}#{[1, 0, 0, 0, 0, 0, 0, 3, 0, 0].pack('C*')}".b,
     # A wild end of the user range.
     "\x02#{[0x10000].pack('Q>')}#{reserve}".b,
     "#{window}#{reserve}#{commit}#{edges}".b]
  )
)
