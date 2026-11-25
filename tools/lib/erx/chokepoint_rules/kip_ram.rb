# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

module Erx
  module ChokepointRules
    declare_group(none: 'it has no private header and no state: one pure function that classifies a memory descriptor ' \
                        'of Fiasco\'s kernel information page for the readable-RAM map')
  end
end
