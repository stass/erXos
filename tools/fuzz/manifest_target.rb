# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require_relative 'manifest_seeds'

# The system manifest's generated C reader.
Erx::PackFuzz.declare_target(
  sources: ['liberx/generated/abi_reader.c'],
  seeds: Erx::ManifestSeeds.all
)
