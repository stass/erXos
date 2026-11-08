# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

# The object store, fed an id key, creation counters, operations on its
# headers in any order their contracts allow, and handles of any value.
# The seeds walk a header through its whole life, spend the counter, and
# look up handles in and out of the test store. Host handles index the
# test store, so the store is built as the host tests build it.
key = [1, 2, 3, 4].pack('Q<4')
Erx::PackFuzz.declare_target(
  sources: ['kernel/core/object.c'],
  defines: ['ERX_HOST'],
  seeds: Erx::PackFuzz.indexed_seeds(
    ["#{key}#{[0].pack('Q<')}\x00\x01\x01\x02\x04\x02\x03\x01\x05\x05",
     "#{key}#{[0xffff_ffff_ffff_fffd].pack('Q<')}\x00\x08\x10\x18\x0b\x13",
     "#{key}#{[9].pack('Q<')}\x00\x08\x07#{[1].pack('Q<')}\x07#{[4].pack('Q<')}\x07#{[5].pack('Q<')}" \
     "\x06#{[0].pack('Q<')}\x00"]
  )
)
