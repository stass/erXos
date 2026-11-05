# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

module Erx
  module ChokepointRules
    DEVICE_DESIGN = 'docs/design-runtime.md#the-device-nif'
    DEVICE_NIFS = 'otp/erts/emulator/nifs/erxos'
    DEVICE_SCOPE = Chokepoints::Scope.new(own: true, extra: ['otp/**/*'], except: ['otp/erts/emulator/asmjit/**/*'])

    declare_group(
      rules: [
        # With no other mapping of device memory in a runtime, nothing else can reach one.
        Chokepoints::Forbidden.new(
          name: 'device-memory-mapping',
          rule: "only erx_device makes a runtime's mapping of device memory",
          design: DEVICE_DESIGN,
          scope: Chokepoints::Scope.new(own: false, extra: ['otp/**/*'], except: ['otp/erts/emulator/asmjit/**/*']),
          pattern: /\berx_(?:mem_create_physical|vm_map)\b/,
          sites: [Chokepoints::Site.new(glob: "#{DEVICE_NIFS}/erx_device.c")],
          seed: { 'otp/erts/emulator/beam/seeded.c' => "void f(void) { erx_mem_create_physical(0, 0, 0, 0, 0, 0); }\n",
                  'otp/erts/emulator/nifs/erxos/seeded.c' => "void f(void) { erx_vm_map(0, 0, 0, 0, 0, 0); }\n" }
        ),
        Chokepoints::Forbidden.new(
          name: 'device-register-access',
          rule: "only erx_device.c uses the generated accessors that touch a register window",
          design: DEVICE_DESIGN,
          scope: DEVICE_SCOPE,
          pattern: /\berx_device_access_(?:load|store)\d+\b/,
          sites: [Chokepoints::Site.new(glob: "#{DEVICE_NIFS}/erx_device.c"),
                  Chokepoints::Site.new(glob: 'include/erx/hw/device_access.h')],
          seed: { 'otp/erts/emulator/beam/seeded.c' => "void f(void) { erx_device_access_load32(0, 0); }\n" }
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
                  Chokepoints::Site.new(glob: 'test/fixtures/erx_device_harness.c')],
          seed: { 'otp/erts/emulator/sys/erxos/seeded.c' => "void f(void) { erx_device_read(0, 0, e, 0); }\n" }
        ),
        # A device address reaches no runtime code but erx_device's, and its pools and queues have not come yet.
        Chokepoints::Forbidden.new(
          name: 'device-dma-calls',
          rule: 'no runtime code outside erx_device calls erx_dma_map or erx_mem_dma_addr',
          design: DEVICE_DESIGN,
          scope: Chokepoints::Scope.new(own: false, extra: ['otp/**/*'], except: ['otp/erts/emulator/asmjit/**/*']),
          pattern: /\berx_(?:dma_map|mem_dma_addr)\b/,
          seed: { 'otp/erts/emulator/beam/seeded.c' => "void f(void) { erx_mem_dma_addr(0, 0, 0); }\n" }
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
