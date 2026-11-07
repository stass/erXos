# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

# littlefs images as /data mounts them (lfs_image_fuzz.c): raw blocks, and a volume
# formatted in the harness with patches over its superblock, its metadata pairs and a
# file's data. littlefs is its import in littlefs/.
littlefs = 'littlefs'
Erx::PackFuzz.declare_target(
  sources: ["#{littlefs}/lfs.c", "#{littlefs}/lfs_util.c"],
  includes: [*Erx::PackFuzz::INCLUDES, littlefs, 'otp/erts/emulator/nifs/erxos'],
  seeds: {
    'raw-zero' => "\x00".b + ("\x00" * 64).b,
    'raw-ones' => "\x00".b + ("\xff" * 4096).b,
    'formatted' => "\x01".b,
    'formatted-superblock' => "\x01\x00\x08\x00\x00\x10\x41".b,
    'formatted-pair' => "\x01\x10\x04\xff\x20\x00\x00\x30\x08\x7f".b,
    'formatted-tail' => "\x01\x7f\xf0\x01\x7f\xf8\x00".b
  }
)
