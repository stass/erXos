# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require_relative '../../tools/lib/erx/generated'

# Tests that compile C read the generated headers and sources from the
# build tree (build/gen), so requiring this brings that tree up to date with
# the generators' inputs, once per test process. Erx::Generated.ensure
# serializes parallel test processes on its lock and is a no-op when the
# tree is fresh.
Erx::Generated.ensure(root: File.expand_path('../..', __dir__))
