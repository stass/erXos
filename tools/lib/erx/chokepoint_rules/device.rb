# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require_relative '../hardware'

module Erx
  module ChokepointRules
    DEVICE_DESIGN = 'docs/design-runtime.md#the-device-nif'
    DEVICE_NIFS = 'otp/erts/emulator/nifs/erxos'
    ERX_DEVICE = 'erlang/apps/erx/src/erx_device.erl'
    ERX_IRQ_LINE = 'erlang/apps/erx/src/erx_irq_line.erl'
    BLK_WRITE = 'erlang/apps/erx_blk/src/erx_blk_write.erl'
    # The applications whose modules drive a device class.
    DRIVER_APPLICATIONS = %w[erx_blk erx_fb erx_uart].freeze

    # A call of erx_device's issuing function name: erx_device followed by
    # the name after a colon (a remote call or fun) or a comma (an apply),
    # or any import from erx_device, which names it bare.
    def self.device_issue(name)
      device = ErlangText::ATOM.call('erx_device')
      /#{device} \s* (?: : | , ) \s* #{ErlangText::ATOM.call(name)} | -\s*import\s*\(\s*#{device}/x
    end

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
          rule: "only erx_device makes a runtime's mapping of device memory; the lane and program drivers, the crash area, the domain library NIF and the pixel area NIF map memory objects",
          design: DEVICE_DESIGN,
          scope: Chokepoints::Scope.new(own: false, extra: ['otp/**/*'], except: ['otp/erts/emulator/asmjit/**/*']),
          pattern: /\berx_(?:mem_create_physical|vm_map)\b/,
          # The lane port driver maps a connection's two lane sides, memory objects the system
          # domain created, never device memory; it calls no erx_mem_create_physical.
          # erx_jit_memory.c maps only the JIT object it has just created, never device
          # memory, at its two aliases. erx_crash_area.c maps the domain's crash area and the
          # domain library NIF, read-only, the object it creates to copy one into.
          # erx_program_drv.c maps the session's two sides of a program's channel, memory
          # objects it has just created from the session's budget, never device memory.
          # erx_pipe_nif.c maps a pipe's lock page, rings and reader pages, memory objects the
          # pipe server created from the session's budget, never device memory.
          # erx_area_nif.c maps a connection's pixel area, a memory object the system domain
          # created with the connection, never device memory.
          sites: [Chokepoints::Site.new(glob: "#{DEVICE_NIFS}/erx_device.c"),
                  Chokepoints::Site.new(glob: 'otp/erts/emulator/sys/erxos/erx_program_drv.c', permits: /\Aerx_vm_map\z/),
                  Chokepoints::Site.new(glob: 'otp/erts/emulator/sys/erxos/erx_jit_memory.c', permits: /\Aerx_vm_map\z/),
                  Chokepoints::Site.new(glob: 'otp/erts/emulator/sys/erxos/erx_lane_drv.c', permits: /\Aerx_vm_map\z/),
                  Chokepoints::Site.new(glob: 'otp/erts/emulator/sys/erxos/erx_crash_area.c', permits: /\Aerx_vm_map\z/),
                  Chokepoints::Site.new(glob: "#{DEVICE_NIFS}/erx_domain_lib_nif.c", permits: /\Aerx_vm_map\z/),
                  Chokepoints::Site.new(glob: "#{DEVICE_NIFS}/erx_pipe_nif.c", permits: /\Aerx_vm_map\z/),
                  Chokepoints::Site.new(glob: "#{DEVICE_NIFS}/erx_area_nif.c", permits: /\Aerx_vm_map\z/)],
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
                  Chokepoints::Site.new(glob: 'test/fixtures/erx_device_dma_harness.c'),
                  # GENET's harness, whose stand-in engines answer the register ring through them.
                  Chokepoints::Site.new(glob: 'test/fixtures/erx_device_genet_harness.c')],
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
        # The sequencer orders every clean, invalidate and barrier of a queue call, and
        # erx_device.c's effect layer runs its plan under the device lock, so a call from anywhere
        # else would issue maintenance outside any plan. The architecture layer's header declares
        # them, each architecture's erx_dma_arch.c defines them, and so does the counting double
        # the DMA harness links in place of the hosted model; the harnesses themselves reach them
        # only through erx_device. erx_dma_granule and erx_dma_line are queries and stay free.
        Chokepoints::Forbidden.new(
          name: 'device-dma-maintenance',
          rule: "only erx_device.c's effect layer calls the DMA architecture layer's cache maintenance and barriers",
          design: 'docs/design-device-dma.md#the-architecture-layer',
          scope: DEVICE_SCOPE,
          pattern: /\berx_dma_(?:clean|clean_inval|publish_barrier|report_barrier|completion_barrier)\b/,
          sites: [Chokepoints::Site.new(glob: "#{DEVICE_NIFS}/erx_device.c"),
                  Chokepoints::Site.new(glob: "#{DEVICE_NIFS}/erx_dma_arch.h"),
                  Chokepoints::Site.new(glob: "#{DEVICE_NIFS}/arch/*/erx_dma_arch.c"),
                  Chokepoints::Site.new(glob: 'test/fixtures/erx_dma_arch_counting.c')],
          seed: { 'otp/erts/emulator/nifs/erxos/erx_device_bif.c' => "void f(void) { erx_dma_clean(0, 0, 64); }\n",
                  'otp/erts/emulator/beam/seeded.c' => "void f(void) { erx_dma_completion_barrier(); }\n",
                  'test/fixtures/erx_device_dma_harness.c' => "void f(void) { erx_dma_publish_barrier(1); }\n" }
        ),
        Chokepoints::Forbidden.new(
          name: 'device-table-include',
          rule: 'only erx_device_core.c includes the generated table, whose static data has one owner',
          design: DEVICE_DESIGN,
          scope: DEVICE_SCOPE,
          pattern: %r{erx/hw/device_table\.h},
          sites: [Chokepoints::Site.new(glob: "#{DEVICE_NIFS}/erx_device_core.c")],
          seed: { 'otp/erts/emulator/beam/seeded.c' => "#include \"erx/hw/device_table.h\"\n" }
        ),
        # The Erlang half: ERTS binds a static NIF only to the module of its
        # name, and erx_device's register calls are BIFs of that module, so
        # Erlang reaches a device only by naming erx_device. Only erx_device,
        # erx_irq_line, which binds and acknowledges lines for drivers
        # (docs/design-shared-devices.md, "Lines inside a domain"), and the
        # driver applications, one per device class, name it: as a call, an
        # apply's module literal, a quoted atom or a string. What keeps a device
        # from other domains is that its capability is installed only in its
        # driver's domain.
        Chokepoints::ErlangForbidden.new(
          name: 'device-callers', rule: 'only erx_device, erx_irq_line and the driver applications name erx_device, ' \
                                        'whose NIF and BIFs reach a device',
          design: DEVICE_DESIGN, pattern: /(?<![A-Za-z0-9_@])erx_device(?![A-Za-z0-9_@])/,
          sites: [ERX_DEVICE, ERX_IRQ_LINE, *DRIVER_APPLICATIONS.map { |application| "erlang/apps/#{application}/**/*" },
                  # erXos's own directory of the network stack, whose other modules name nothing of erXos's
                  # (docs/design-network-stack.md, "Two places, four seams").
                  'erlang/apps/erx_net/erxos/**/*'],
          seed: { 'otp/lib/stdlib/src/seeded.erl' => "f(D) -> erx_device:read(D, dr).\n",
                  'erlang/apps/erx_files/src/seeded.erl' => "f() -> \"erx_device\".\n" }
        ),
        # No driver binds a shared line and takes its deliveries from the drivers
        # joined to its owner, nor binds or acknowledges a line past erx_irq_line
        # (SD3); a literal table names the function as surely as a call does.
        Chokepoints::ErlangForbidden.new(
          name: 'device-line-calls', rule: 'only erx_device and erx_irq_line name irq_bind, irq_bind_owner or irq_ack: ' \
                                           'a driver attaches and acknowledges its lines through erx_irq_line',
          design: 'docs/design-shared-devices.md#lines-inside-a-domain',
          pattern: /(?<![A-Za-z0-9_@])irq_(?:bind|bind_owner|ack)(?![A-Za-z0-9_@])/, sites: [ERX_DEVICE, ERX_IRQ_LINE],
          seed: { 'erlang/apps/erx_uart/src/seeded.erl' => "f(D) -> erx_device:irq_bind_owner(D, 0).\n" }
        ),
        # A block device reads or writes the medium only for a request a driver
        # posts, and erx_blk_write is the one block module that posts: it builds
        # every request, and only its write/6 one whose type writes
        # (docs/design-storage.md, U4). The network transports post frames and
        # the virtio-gpu driver requests its pure core built, to devices handed
        # no medium (docs/design-display.md, "The display device"). Refused
        # outside them: erx_device:post as a remote call or fun, erx_device with
        # post as an apply's next argument, and any import from erx_device.
        Chokepoints::ErlangForbidden.new(
          name: 'device-posters', rule: "only the block driver's one write path, erx_blk_write, the network transports and the " \
                                        'virtio-gpu driver call erx_device:post/4, and each builds every request it posts',
          design: 'docs/design-storage.md#data-model', pattern: device_issue('post'),
          sites: [BLK_WRITE, 'erlang/apps/erx_net/erxos/erx_virtio_net.erl', 'erlang/apps/erx_net/erxos/erx_genet.erl',
                  'erlang/apps/erx_fb/src/erx_virtio_gpu.erl'],
          seed: { 'erlang/apps/erx_blk/src/seeded.erl' => "f(D) -> erx_device:post(D, 0, <<>>, 0).\n",
                  'erlang/apps/erx_blk/src/seeded_import.erl' => "-import(erx_device, [post/4]).\n" }
        ),
        # An SD host controller acts when its command register is written, which
        # only erx_device:command/2 does; the SD write path builds every command
        # word, and only its write function CMD24 or CMD25.
        Chokepoints::ErlangForbidden.new(
          name: 'device-commands', rule: "only the block driver's one write path, erx_blk_write, calls erx_device:command/2",
          design: 'docs/design-storage.md#data-model', pattern: device_issue('command'), sites: [BLK_WRITE],
          seed: { 'erlang/apps/erx_net/erxos/erx_virtio_net.erl' => "f(D) -> apply(erx_device, command, [D, 0]).\n" }
        )
      ],
      unchecked_objects: []
    )
  end
end
