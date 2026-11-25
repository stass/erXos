# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

module Erx
  # The atom-count warm-up of the Erlang fuzz targets. A target calls
  # erx_fuzz_warm:closure(?MODULE) before its first round, so the module that
  # defines it must be compiled beside the target: a driver passes SOURCE to
  # erlc with the target's own sources.
  module FuzzWarm
    SOURCE = File.expand_path('../../../test/erlang/erx_fuzz_warm.erl', __dir__)
  end
end
