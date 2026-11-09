# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require_relative '../../test/fixtures/image_fixture'

# The planner of an image entry's manifest and segments (erx_image_plan).
Erx::PackFuzz.declare_target(sources: ['liberx/image_plan.c', 'build/gen/liberx/generated/abi_reader.c'],
                             seeds: Erx::PackFuzz.prefix_seeds(ImageFixture.valid))
