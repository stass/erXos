# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require_relative '../hardware'

module Erx
  module ChokepointRules
    DEVICE_DESIGN = 'docs/design-runtime.md#the-device-nif'
    DEVICE_NIFS = 'otp/erts/emulator/nifs/erxos'
    DEVICE_SCOPE = Chokepoints::Scope.new(own: true, extra: ['otp/**/*'], except: ['otp/erts/emulator/asmjit/**/*'])
    # The accessors tools/gen_hw.rb writes for each SVD peripheral, and their headers, read from
    # the generator, so a new device or register is covered as it is generated. A runtime reaches
    # a register window only through erx_device's table; in the kernel only the platform layer
    # may use them, where the kernel's own row narrows them to the early-console writer
    # (docs/design-kernel.md, "Chokepoint checks"). These text rules catch a slip, not a
    # determined bypass (a macro include, token pasting, a hand-written volatile access): what
    # keeps a runtime off device registers is that only erx_device maps device memory.
    PERIPHERALS = Hardware.devices(root: REPOSITORY)
    PERIPHERAL_HEADERS = PERIPHERALS.map { |device| Hardware.device_header_path(device) }.freeze
    PERIPHERAL_SYMBOLS = PERIPHERALS.flat_map { |device| Hardware.generated_symbols(device) }.freeze
    # An include of one of those headers by its path below include/, in any case, so a header
    # elsewhere that shares a peripheral's file name (timer.h, rtc.h) stays free.
    PERIPHERAL_INCLUDE_PATHS = PERIPHERAL_HEADERS.map { |header| Regexp.escape(header.delete_prefix('include/')) }.freeze
    PERIPHERAL_INCLUDE = %r{#{INCLUDE}[<"](?:#{PERIPHERAL_INCLUDE_PATHS.join('|')})[>"]}i
    PERIPHERAL_OWNERS = [Chokepoints::Site.new(glob: 'kernel/platform/**/*')].freeze
    # The prefix of every name Hardware.owned_symbols makes, so no list can fall behind the SVD files.
    OWNED_REGISTER = /\bERX_DEVICE_OWNED_\w+/

    declare_group(
      rules: [
        # With no other mapping of device memory in a runtime, nothing else can reach one.
        Chokepoints::Forbidden.new(
          name: 'device-memory-mapping',
          rule: "only erx_device makes a runtime's mapping of device memory",
          design: DEVICE_DESIGN,
          scope: Chokepoints::Scope.new(own: false, extra: ['otp/**/*'], except: ['otp/erts/emulator/asmjit/**/*']),
          pattern: /\berx_(?:mem_create_physical|vm_map)\b/,
          # erx_jit_memory.c maps only the JIT object it has just created, never device
          # memory, at its two aliases.
          sites: [Chokepoints::Site.new(glob: "#{DEVICE_NIFS}/erx_device.c"),
                  Chokepoints::Site.new(glob: 'otp/erts/emulator/sys/erxos/erx_jit_memory.c', permits: /\Aerx_vm_map\z/)],
          seed: { 'otp/erts/emulator/beam/seeded.c' => "void f(void) { erx_mem_create_physical(0, 0, 0, 0, 0, 0); }\n",
                  'otp/erts/emulator/nifs/erxos/seeded.c' => "void f(void) { erx_vm_map(0, 0, 0, 0, 0, 0); }\n",
                  'otp/erts/emulator/sys/common/erl_mmap.c' => "void f(void) { erx_vm_map(0, 0, 0, 0, 0, 0); }\n",
                  'otp/erts/emulator/sys/erxos/erx_jit_memory.c' =>
                    "void f(void) { erx_mem_create_physical(0, 0, 0, 0, 0, 0); }\n" }
        ),
        Chokepoints::Forbidden.new(
          name: 'device-register-access',
          rule: "only erx_device.c uses the generated accessors that touch a register window",
          design: DEVICE_DESIGN,
          scope: DEVICE_SCOPE,
          pattern: /\berx_device_access_(?:load|store)\d+\b/,
          sites: [Chokepoints::Site.new(glob: "#{DEVICE_NIFS}/erx_device.c"),
                  Chokepoints::Site.new(glob: 'include/erx/hw/device_access.h'),
                  # The DMA harness's device model, which stands in for the generated accesses.
                  Chokepoints::Site.new(glob: 'test/fixtures/device_model/erx/hw/device_access.h'),
                  Chokepoints::Site.new(glob: 'test/fixtures/erx_device_dma_harness.c')],
          seed: { 'otp/erts/emulator/beam/seeded.c' => "void f(void) { erx_device_access_load32(0, 0); }\n" }
        ),
        # The generated peripheral accessors are static inline, so they leave no symbol for the
        # import check, and a header and a call are all a bypass of erx_device needs.
        Chokepoints::Forbidden.new(
          name: 'device-peripheral-headers',
          rule: 'only the kernel platform layer includes a generated peripheral header',
          design: DEVICE_DESIGN,
          scope: DEVICE_SCOPE,
          pattern: PERIPHERAL_INCLUDE,
          sites: PERIPHERAL_OWNERS,
          seed: { 'otp/erts/emulator/beam/seeded.c' => "#include <erx/hw/pl011.h>\n" }
        ),
        Chokepoints::Forbidden.new(
          name: 'device-peripheral-accessors',
          rule: 'only the generated peripheral headers and the kernel platform layer name their accessors',
          design: DEVICE_DESIGN,
          scope: DEVICE_SCOPE,
          pattern: /\b(?:#{PERIPHERAL_SYMBOLS.map { |symbol| Regexp.escape(symbol) }.join('|')})\b/,
          sites: PERIPHERAL_HEADERS.map { |header| Chokepoints::Site.new(glob: header) } + PERIPHERAL_OWNERS,
          seed: { 'otp/erts/emulator/nifs/erxos/seeded.c' => "void f(erx_mmio_t d) { erx_pl011_dr_write(d, 65); }\n" }
        ),
        Chokepoints::Forbidden.new(
          name: 'device-register-callers',
          rule: "only erx_device's BIFs, and its tests through the C interface, call its register accesses",
          design: DEVICE_DESIGN,
          scope: DEVICE_SCOPE,
          pattern: /\berx_device_(?:read|write)(?:_field)?\b/,
          sites: [Chokepoints::Site.new(glob: "#{DEVICE_NIFS}/erx_device.c"),
                  Chokepoints::Site.new(glob: "#{DEVICE_NIFS}/erx_device.h"),
                  Chokepoints::Site.new(glob: "#{DEVICE_NIFS}/erx_device_bif.c"),
                  Chokepoints::Site.new(glob: 'test/guest/native_irq/guest.c'),
                  Chokepoints::Site.new(glob: 'test/fixtures/erx_device_harness.c'),
                  Chokepoints::Site.new(glob: 'test/fixtures/erx_device_dma_harness.c')],
          seed: { 'otp/erts/emulator/sys/erxos/seeded.c' => "void f(void) { erx_device_read(0, 0, e, 0); }\n" }
        ),
        # write/3 and write_field/4 refuse a register the SVD source marks ownedByNif, and only
        # erx_device.c holds the raw accessors, so the NIF's own sequences alone write one. This
        # keeps the generated names of owned registers, which those sequences use, in that file.
        Chokepoints::Forbidden.new(
          name: 'device-owned-registers',
          rule: 'only erx_device.c names a register the device NIF owns',
          design: DEVICE_DESIGN,
          scope: DEVICE_SCOPE,
          pattern: OWNED_REGISTER,
          sites: [Chokepoints::Site.new(glob: "#{DEVICE_NIFS}/erx_device.c"),
                  Chokepoints::Site.new(glob: 'include/erx/hw/device_owned.h')],
          seed: { 'otp/erts/emulator/nifs/erxos/seeded.c' => "unsigned x = ERX_DEVICE_OWNED_VIRTIO_MMIO_STATUS;\n",
                  'otp/erts/emulator/beam/seeded.c' => "unsigned y = ERX_DEVICE_OWNED_VIRTIO_MMIO_QUEUE_READY;\n" }
        ),
        # A device address reaches no runtime code but erx_device.c's, which builds every one for its queues.
        Chokepoints::Forbidden.new(
          name: 'device-dma-calls',
          rule: 'no runtime code outside erx_device calls erx_dma_map or erx_mem_dma_addr',
          design: DEVICE_DESIGN,
          scope: Chokepoints::Scope.new(own: false, extra: ['otp/**/*'], except: ['otp/erts/emulator/asmjit/**/*']),
          pattern: /\berx_(?:dma_map|mem_dma_addr)\b/,
          sites: [Chokepoints::Site.new(glob: "#{DEVICE_NIFS}/erx_device.c")],
          seed: { 'otp/erts/emulator/beam/seeded.c' => "void f(void) { erx_mem_dma_addr(0, 0, 0); }\n",
                  'otp/erts/emulator/nifs/erxos/seeded.c' => "void f(void) { erx_dma_map(0, 0, 0, 0, 0); }\n" }
        ),
        Chokepoints::Forbidden.new(
          name: 'device-table-include',
          rule: 'only erx_device_core.c includes the generated table, whose static data has one owner',
          design: DEVICE_DESIGN,
          scope: DEVICE_SCOPE,
          pattern: %r{erx/hw/device_table\.h},
          sites: [Chokepoints::Site.new(glob: "#{DEVICE_NIFS}/erx_device_core.c")],
          seed: { 'otp/erts/emulator/beam/seeded.c' => "#include \"erx/hw/device_table.h\"\n" }
        )
      ],
      unchecked_objects: []
    )
  end
end
