# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

module Erx
  module ChokepointRules
    declare_group(none: 'a pure reader of the kernel command line, which the kernel and the root each call on their ' \
                        'own copy of the line; it writes only its caller\'s erx_boot_args_t and reaches no state')
  end
end
