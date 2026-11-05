# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

module Erx
  module ChokepointRules
    declare_group(none: 'it has no private header: include/erx/ns.h and include/erx/release_fs.h hold values their callers own')
  end
end
