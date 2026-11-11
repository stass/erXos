# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

module Erx
  module ChokepointRules
    declare_group(
      none: 'it is a pure check of a frame profile with no private header: include/erx/profile.h and the ' \
            "generated include/erx/prog_profile.h are its whole interface, and the program protocol's own " \
            'rule, a safe erts_decode_ext in the erx_program driver alone, lands with that driver',
      unchecked_objects: %w[liberx/erx_profile.c liberx/generated/prog_profile.c]
    )
  end
end
