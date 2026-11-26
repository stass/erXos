# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

module Erx
  module ChokepointRules
    declare_group(none: 'a pure decision over the call\'s words, with no private header and no effect: the glue maps, and ' \
                        'the kernel answers a second call with -L4_EEXIST, so no rule is needed to keep the map to one caller')
  end
end
