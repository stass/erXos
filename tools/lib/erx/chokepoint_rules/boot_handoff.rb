# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

module Erx
  module ChokepointRules
    declare_group(none: 'it has no private header: include/erx/core/boot_handoff.h defines its view for the glue, ' \
                        'and the record it reads is a layout of the ABI file')
  end
end
