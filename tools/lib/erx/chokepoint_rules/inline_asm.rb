# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require_relative '../sysreg_headers'

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
          rule: 'inline assembly only in the listed files: the generated kernel-call stubs and ' \
                "system-register reads, the barrier, counter and cache-maintenance helpers of liberx's " \
                'backends and the DMA architecture layer, ' \
                "musl's cancellation-point labels, erx_net's checksum fence, and the test programs and " \
                "fixtures that plant instructions, and the raspi4b suite's firmware stand-in",
          design: "#{KERNEL}#chokepoint-checks",
          scope: INLINE_ASM_SCOPE,
          pattern: ASM_KEYWORD,
          sites: [
            # The kernel-call stubs tools/lib/erx/abi_emit_calls.rb writes for each backend.
            Chokepoints::Site.new(glob: 'liberx/backend/erx/arch/aarch64/generated/calls.c'),
            Chokepoints::Site.new(glob: 'liberx/backend/fiasco/arch/aarch64/generated/trap.c'),
            # The system-register reads tools/lib/erx/sysreg_headers.rb writes, one function per
            # register; the sysreg-read rule below holds their callers to a list.
            Chokepoints::Site.new(glob: SysregHeaders::READS),
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
            Chokepoints::Site.new(glob: 'test/fixtures/stack_graph/*.c'),
            # The raspi4b suite's stand-in for the firmware's framebuffer setup: its entry sets the
            # stack and enters BL31 with the registers as reset leaves them; no image holds it.
            Chokepoints::Site.new(glob: 'test/raspi4b/firmware_fb.c')
          ],
          seed: { 'liberx/seeded.c' => "void f(void) { __asm__ volatile(\"dmb sy\" ::: \"memory\"); }\n",
                  'otp/erts/emulator/nifs/erxos/erx_device.c' => "void f(void) { __asm volatile(\"dsb sy\"); }\n",
                  'otp/erts/emulator/nifs/erxos/arch/host/erx_dma_arch.c' => "void f(void) { asm(\"nop\"); }\n",
                  'otp/erts/emulator/sys/erxos/seeded.c' => "void f(void) { __asm__(\"isb\"); }\n",
                  'kernel/core/seeded.c' => "void f(void) { __asm__ volatile(\"isb\"); }\n" }
        ),
        # The generated system-register reads (tools/lib/erx/sysreg_headers.rb) are a site of
        # the rule above, so their instructions reach every file that includes their header
        # without that file's text naming asm. This rule holds those files to a list: it refuses
        # an include of the header as well as a reader's name, and each read is static inline,
        # so a file that does not include the header has no read, however a macro spells its
        # name (include-form refuses an include whose path a macro computes).
        Chokepoints::Forbidden.new(
          name: 'sysreg-read',
          rule: "generated system-register reads only in the listed files: the reader of the boot CPU's " \
                'identification registers, which bootstrap calls',
          design: "#{KERNEL}#chokepoint-checks",
          scope: Chokepoints::Scope.new(own: true, extra: [*INLINE_ASM_SCOPE.extra, 'fiasco/bootstrap/server/src/erx_*']),
          pattern: Regexp.union(/\berx_sysreg_\w+_read\b/, include_of(SysregHeaders::READS)),
          sites: [
            # The header that defines the reads.
            Chokepoints::Site.new(glob: SysregHeaders::READS),
            # erx_boot_cpu_id_read, which bootstrap calls in kernel mode, and its include.
            Chokepoints::Site.new(glob: 'kernel/arch/aarch64/cpu_id.c')
          ],
          seed: { 'liberx/seeded.c' => "unsigned long f(void) { return erx_sysreg_id_aa64isar0_el1_read(); }\n",
                  'kernel/core/seeded.c' => "#include \"erx/arch/aarch64/sysreg.h\"\n",
                  'fiasco/bootstrap/server/src/erx_image.cc' => "void f() { (void)erx_sysreg_cntvct_el0_read(); }\n" }
        )
      ]
    )
  end
end
