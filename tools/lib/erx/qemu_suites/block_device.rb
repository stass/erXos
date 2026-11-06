# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require_relative '../block_device'
require_relative '../qemu_gate'

# The block driver on QEMU virt under HVF: the development image boots with one raw
# disk on the virtio-mmio bus, the driver reads the sectors the harness patterned,
# is refused a read past the end, and writes two sectors, and the harness reads the
# image back (tools/lib/erx/block_device.rb, whose header defines the lines the
# driver prints and what the image must then hold). Run raises on the first
# disagreement, which the gate reports as this suite failing. HVF at one CPU is
# its one cell. check_qemu builds the kernel before any suite runs, so this suite
# does not.
#
# Until the driver exists the guest prints none of the lines, so the suite reports
# its cell pending and boots nothing. The driver's landing sets
# Erx::BlockDevice::DRIVER_LANDED.
cells = Erx::QemuGate.suite_cells([1])
Erx::QemuGate.declare_suite(
  cells: cells,
  run: lambda do |context|
    next Erx::QemuGate.result(cells.to_h { |cell| [cell, 'pending'] }, notes: ['the block driver has not landed']) unless Erx::BlockDevice::DRIVER_LANDED

    run = Erx::BlockDevice::Run.new(root: context.root)
    Erx::QemuGate.result(run.call(accels: [Erx::QemuGate::SUITE_ACCELERATOR], jobs: context.jobs, build: false))
  end
)
