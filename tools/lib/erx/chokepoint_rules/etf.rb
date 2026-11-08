# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

module Erx
  module ChokepointRules
    declare_group(
      none: 'it is a pure codec with no private header: include/erx/etf.h is its whole interface, and the ' \
            "funnel's own rule decides who may decode a lane's frames",
      unchecked_objects: %w[liberx/erx_etf.c]
    )
  end
end
