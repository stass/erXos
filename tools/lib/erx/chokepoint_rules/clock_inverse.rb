# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

module Erx
  module ChokepointRules
    declare_group(none: 'it has no private header or state: one pure function of the clock arithmetic, ' \
                        "which include/erx/core/clock_inverse.h declares for Fiasco's glue")
  end
end
