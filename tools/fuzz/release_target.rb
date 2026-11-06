# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require_relative '../../test/fixtures/pack_fixture'

# erx_release_bind and erx_release_entry, which must accept only what
# a name list can name. The first input byte's bit 0 recomputes the index
# hash. The seeds are a valid archive with its prefixes, and archives on each
# side of the name and count limits, which are the design's: 255 bytes, 256 names.
archive = lambda do |path|
  "\x01".b + PackFixture.valid(paths: [path, 'system/manifest', 'system/root'].sort)
end
valid = archive.call('system/lib/a')
Erx::PackFuzz.declare_target(
  sources: ['kernel/core/pack.c', 'kernel/crypto/blake3/blake3.c', 'kernel/crypto/blake3/blake3_portable.c',
            'liberx/generated/abi_reader.c', 'liberx/release.c', 'liberx/release_fs.c'],
  seeds: Erx::PackFuzz.prefix_seeds(valid).merge(
    'valid-unfixed' => "\x00".b + valid.byteslice(1..),
    'longest-name' => archive.call("system/#{'z' * 255}"),
    'name-too-long' => archive.call("system/#{'z' * 256}"),
    'most-names' => archive.call((['system'] + ['z'] * 256).join('/')),
    'too-many-names' => archive.call((['system'] + ['z'] * 257).join('/')),
    'long-name-outside' => archive.call("other/#{'z' * 256}")
  )
)
