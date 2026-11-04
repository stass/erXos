# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

# The scheduler core. A valid root under C0, then a thread, a group, wakes
# and picks of every reason, so mutations start with threads on the queues;
# and one grant each with an urgency, a flag and padding the kernel refuses.
grant = [(1 << 64) - 1, 10_000_000, 15, 4000, 0, 5000, 50, 16, 31, 0, 0].pack('Q<Q<Q<L<L<L<L<CCS<L<').freeze

Erx::PackFuzz.declare_target(
  sources: ['kernel/sched/sched.c'],
  includes: [*Erx::PackFuzz::INCLUDES, 'kernel/sched'],
  seeds: Erx::PackFuzz.indexed_seeds(
    [grant + "\x01\x02\x00\x05\x00\x09\x00\x00\x00\x00\x00\x00\x00\x00\x00".b,
     grant + "\x01\x00\x00#{grant}\x02\x01\x12\x01\x05\x00\x15\x01\x09\x00".b +
       "\x00\x00\x00\x00\x00\x00\x00\x00\x09\x01\x00\x10\x00\x00\x00\x00\x00\x00\x09\x02" \
       "\x00\x00\x00\x00\x00\x00\x00\x00\x09\x03\x00\x00\x00\x00\x00\x00\x00\x00".b,
     grant + "\x01\x01\x00#{grant.dup.tap { |bytes| bytes.setbyte(40, 64) }}".b,
     grant + "\x01\x01\x00#{grant.dup.tap { |bytes| bytes.setbyte(43, 0x80) }}".b,
     grant + "\x01\x01\x00#{grant.dup.tap { |bytes| bytes.setbyte(44, 1) }}".b]
  )
)
