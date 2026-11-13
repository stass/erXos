# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require_relative 'manifest_seeds'

# The system manifest's generated C reader, and the domain library's boot view
# over what it accepts.
Erx::PackFuzz.declare_target(
  sources: ['build/gen/liberx/generated/abi_reader.c', 'liberx/system/dom_boot_view.c', 'liberx/system/dom_core.c',
            'liberx/system/dom_life.c', 'liberx/erx_lane.c', 'liberx/backend/core/boot_manifest.c'],
  includes: [*Erx::PackFuzz::INCLUDES, '.'],
  seeds: Erx::ManifestSeeds.all
)
