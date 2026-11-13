# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

module Erx
  module ChokepointRules
    # The asm keyword in any of its spellings, as GCC and clang accept it.
    ASM_KEYWORD = /\b(?:__asm__|__asm|asm)\b/

    # Inline assembly in erXos's own C, the kernel's and every user-mode
    # program's alike: the runtimes' erXos directories, liberx, the NIFs and
    # musl's erxos directories. The check is by file: each listed site's comment
    # names the functions in it that hold the keyword, which review keeps to
    # those functions; they leave the stack pointer and the link register to
    # the compiler, which the stack proof assumes.
    INLINE_ASM_SCOPE = Chokepoints::Scope.new(
      own: true,
      extra: [GLUE, 'otp/erts/emulator/nifs/erxos/**/*', 'otp/erts/emulator/sys/erxos/**/*']
    )

    declare_group(
      rules: [
        Chokepoints::Forbidden.new(
          name: 'inline-asm',
          rule: 'inline assembly only in the listed files: the generated kernel-call stubs, the barrier, ' \
                "counter and cache-maintenance helpers of liberx's backends and the DMA architecture layer, " \
                "musl's cancellation-point labels, erx_net's checksum fence, and the test programs and " \
                'fixtures that plant instructions',
          design: "#{KERNEL}#chokepoint-checks",
          scope: INLINE_ASM_SCOPE,
          pattern: ASM_KEYWORD,
          sites: [
            # The kernel-call stubs tools/lib/erx/abi_emit_calls.rb writes for each backend.
            Chokepoints::Site.new(glob: 'liberx/backend/erx/arch/aarch64/generated/calls.c'),
            Chokepoints::Site.new(glob: 'liberx/backend/fiasco/arch/aarch64/generated/trap.c'),
            # erx_fiasco_cache_make_coherent.
            Chokepoints::Site.new(glob: 'liberx/backend/fiasco/arch/aarch64/cache.c'),
            # erx_fiasco_counter_hz and erx_fiasco_counter.
            Chokepoints::Site.new(glob: 'liberx/backend/fiasco/arch/aarch64/clock.c'),
            # counter_fence.
            Chokepoints::Site.new(glob: 'liberx/backend/hosted/log.c'),
            # cache_type, erx_dma_clean, erx_dma_clean_inval and the publish, report and
            # completion barriers (docs/design-device-dma.md, "The architecture layer").
            Chokepoints::Site.new(glob: 'otp/erts/emulator/nifs/erxos/arch/aarch64/erx_dma_arch.c'),
            # The file-scope labels of musl's cancellation points, which name no instruction.
            Chokepoints::Site.new(glob: 'musl/src/thread/erxos/syscall_cp.c'),
            # LOADED_ONCE, an empty statement that pins a loaded word in a register.
            Chokepoints::Site.new(glob: 'erlang/apps/erx_net/c_src/erx_inet_csum.c'),
            # rewrite_helper's instruction barrier after another thread rewrote its code.
            Chokepoints::Site.new(glob: 'test/guest/native_task/program.c'),
            # The stack proof's host fixtures, which plant the instructions its extractor must
            # refuse; no build links them.
            Chokepoints::Site.new(glob: 'test/fixtures/stack_graph/*.c')
          ],
          seed: { 'liberx/seeded.c' => "void f(void) { __asm__ volatile(\"dmb sy\" ::: \"memory\"); }\n",
                  'otp/erts/emulator/nifs/erxos/erx_device.c' => "void f(void) { __asm volatile(\"dsb sy\"); }\n",
                  'otp/erts/emulator/nifs/erxos/arch/host/erx_dma_arch.c' => "void f(void) { asm(\"nop\"); }\n",
                  'otp/erts/emulator/sys/erxos/seeded.c' => "void f(void) { __asm__(\"isb\"); }\n",
                  'kernel/core/seeded.c' => "void f(void) { __asm__ volatile(\"isb\"); }\n" }
        )
      ]
    )
  end
end
