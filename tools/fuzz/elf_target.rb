# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require_relative '../../test/fixtures/elf_fixture'

# The parser of ELF executable headers.
Erx::PackFuzz.declare_target(sources: ['liberx/elf_plan.c'], seeds: Erx::PackFuzz.prefix_seeds(ElfFixture.valid))
