# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require_relative '../../test/fixtures/pack_fixture'

# The boot-path parser of the ERXPACK boot image.
Erx::PackFuzz.declare_target(sources: ['kernel/core/pack.c'], seeds: Erx::PackFuzz.prefix_seeds(PackFixture.valid))
