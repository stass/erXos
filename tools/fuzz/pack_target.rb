# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require_relative '../../test/fixtures/pack_fixture'

# The boot-path parser of the ERXPACK boot image's index and file checks.
# The first input byte chooses the fix-ups: 3 recomputes the file hashes and
# the index hash before the check, so mutations reach past them; 0 leaves
# them as written. The seeds are a valid archive in mode 3 with its
# prefixes, the same archive left unfixed, and archives with an empty
# directory: valid, with contents, and above a file.
valid = "\x03".b + PackFixture.valid
with_directory = lambda do |paths, files: {}|
  "\x03".b + PackFixture.valid(paths: [*paths, 'system/root'], directories: ['data'], files: files)
end
Erx::PackFuzz.declare_target(
  sources: ['kernel/core/pack.c', 'liberx/image_plan.c', 'kernel/crypto/blake3/blake3.c', 'kernel/crypto/blake3/blake3_portable.c'],
  seeds: Erx::PackFuzz.prefix_seeds(valid).merge(
    'valid-unfixed' => "\x00".b + valid.byteslice(1..),
    'empty-directory' => with_directory.call(%w[data data-x]),
    'directory-with-contents' => with_directory.call(%w[data], files: { 'data'.b => 'x'.b }),
    'directory-above-a-file' => with_directory.call(%w[data data/x])
  )
)
