# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require_relative '../block_device'
require_relative '../qemu_gate'

# The block driver on QEMU virt under HVF: a test image boots with one raw disk on
# the virtio-mmio bus, its test module reads through the driver the sectors the
# harness patterned, is refused a read past the end, and writes two sectors, and the
# harness reads the image back; a boot on a medium laid out by the ABI file checks the
# block service's windows; and two boots on one fresh medium check that a file synced
# under /data survives a power cut, QEMU killed after the sync, and the next boot
# (tools/lib/erx/block_device.rb, whose header defines the lines the guest prints, what
# the image must then hold, and how the test module reaches the image). Run raises on
# the first disagreement, which the gate reports as this suite failing. HVF at one CPU
# is its one cell, which every boot must pass. check_qemu builds the kernel
# before any suite runs, so this suite does not.
#
# Until the driver starts on the suite's disk, the suite reports its cell pending and
# boots nothing; Erx::BlockDevice::DRIVER_LANDED says when it does.
cells = Erx::QemuGate.suite_cells([1])
Erx::QemuGate.declare_suite(
  cells: cells,
  run: lambda do |context|
    next Erx::QemuGate.result(cells.to_h { |cell| [cell, 'pending'] }, notes: ['the block driver has not landed']) unless Erx::BlockDevice::DRIVER_LANDED

    run = Erx::BlockDevice::Run.new(root: context.root)
    cells = run.call(accels: [Erx::QemuGate::SUITE_ACCELERATOR], jobs: context.jobs, build: false)
    Erx::QemuGate.result(cells, notes: run.notes)
  end
)
