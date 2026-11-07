# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

module Erx
  # The sources of the hosted backend and its function API test. Apart from FunctionApi,
  # which loads the test images' recipe, so that the hosted build's class loads none of it.
  module HostedSources
    GUEST = 'test/guest/function_api'
    ALL = %W[
      kernel/core/admit.c kernel/core/debug_log.c kernel/core/dispatch.c kernel/core/log.c kernel/core/pack.c
      kernel/crypto/blake3/blake3.c kernel/crypto/blake3/blake3_portable.c
      build/gen/kernel/generated/abi_decode.c build/gen/kernel/generated/abi_run.c
      build/gen/liberx/generated/abi_reader.c liberx/release.c liberx/release_fs.c
      liberx/backend/core/object_info.c liberx/backend/core/park_table.c liberx/backend/core/refused.c
      liberx/backend/core/trace_ring.c liberx/backend/core/vm_table.c liberx/backend/hosted/object_info.c
      liberx/backend/hosted/arch/aarch64/switch_stack.S build/gen/liberx/backend/hosted/generated/calls.c
      liberx/backend/hosted/group.c liberx/backend/hosted/log.c liberx/backend/hosted/thread.c
      liberx/backend/hosted/trace.c liberx/backend/hosted/vm.c liberx/backend/hosted/wait.c
      #{GUEST}/cases.c #{GUEST}/hosted.c #{GUEST}/irq_cases.c
    ].freeze
  end
end
