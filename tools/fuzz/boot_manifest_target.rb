# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require_relative 'manifest_seeds'

# What the boot information page takes from the system manifest, then the page it makes.
Erx::PackFuzz.declare_target(
  sources: ['liberx/backend/core/boot_manifest.c', 'liberx/backend/core/boot_info.c'],
  includes: [*Erx::PackFuzz::INCLUDES, '.'],
  seeds: Erx::ManifestSeeds.all
)
