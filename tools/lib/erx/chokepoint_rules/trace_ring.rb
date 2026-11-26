# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

module Erx
  module ChokepointRules
    declare_group(none: 'a pure ring and reader over the ring they are handed, with no private header and no effect: ' \
                        'trace_rings.rb keeps the kernel\'s rings to their one writer')
  end
end
