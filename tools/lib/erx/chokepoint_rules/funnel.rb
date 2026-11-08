# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

module Erx
  module ChokepointRules
    declare_group(
      none: "its grammar is pure, with no private header: include/erx/funnel.h is its whole interface, and the " \
            "rule that only the funnel hands a lane's frames to a runtime lands with erx_funnel_step, its one caller",
      unchecked_objects: %w[liberx/erx_funnel.c]
    )
  end
end
