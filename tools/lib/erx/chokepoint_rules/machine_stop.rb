# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

module Erx
  module ChokepointRules
    declare_group(none: 'it has no private header and no state: pure decisions of the stop and of the readable-RAM map, ' \
                        'which include/erx/core/machine_stop.h declares for each kernel\'s glue')
  end
end
