# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require_relative '../../tools/lib/erx/sanitizer_environment'

# Tests that compile C may run what they build under a sanitizer, so
# requiring this gives every program the test process starts the sanitizer
# policy and the build's llvm-symbolizer, as tools/erx gives the tests it
# runs. A test run directly with ruby then never leaves a report waiting on
# atos (tools/lib/erx/sanitizer_environment.rb says why). A site that changes
# an option passes the change to Erx::SanitizerEnvironment.call instead.
ENV.update(Erx::SanitizerEnvironment.call)
