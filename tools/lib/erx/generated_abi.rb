# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

# Erx::ABI::Generated, the ABI's constants and layouts for the host tools,
# generated from abi/erx_abi.txt into build/gen/tools/generated/abi.rb,
# which uses abi_binary.rb.
require_relative 'abi_binary'
require_relative 'generated'

Erx::Generated.require_ruby('tools/generated/abi.rb')
