# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

# The tree's group and the line editor it calls, which host tests load over stock's:
# group asks its driver for input (edit 72 of docs/design-runtime.md) and passes a read's
# damage into every edlin call (edits 80 and 81), so neither runs with stock's other half.
module LineEditor
  SOURCES = %w[otp/lib/kernel/src/group.erl otp/lib/stdlib/src/edlin.erl
               otp/lib/stdlib/src/edlin_key.erl].freeze
  MODULES = SOURCES.map { |path| File.basename(path, '.erl') }.freeze
  # An Erlang expression sequence, ending in a comma, that loads the compiled modules from
  # the current directory over stock's sticky ones.
  LOAD = MODULES.map { |name| "code:unstick_mod(#{name}), {module, #{name}} = code:load_abs(\"#{name}\"), " }
                .join.freeze
end
