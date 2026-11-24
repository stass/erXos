# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require_relative '../usb_boot'
require_relative '../qemu_gate'

# The usb suite on QEMU virt under HVF (tools/lib/erx/usb_boot.rb): qemu-xhci with a usb-kbd
# and a usb-storage stick behind the PCIe domain, held by the development manifest's USB
# domain. Its cases are cells of the boot: one per enumeration stage, one for the key typed
# through QMP, and the stick's, from its medium served to its sectors read, written, read
# back and flushed, its unplugging and its log lines. A second boot is the restart cell's: its
# USB domain may restart once, and a key typed after the domain's first incarnation is
# killed must reach the display through the new input facet. Its boots carry a QMP socket
# and a disk, which no remote host serves, so it does not declare offload. check_qemu builds the
# kernel before any suite runs, so this suite does not.
cpus = [1]
Erx::QemuGate.declare_suite(
  cells: Erx::QemuGate.suite_cells(cpus).flat_map { |cell| [cell, *Erx::UsbBoot::SIDE_CELLS.map { |side| "#{cell}#{side}" }] },
  run: lambda do |context|
    run = Erx::UsbBoot::Run.new(root: context.root)
    ran = run.call(cpus: cpus, jobs: context.jobs, build: false, placement: context.placement)
    Erx::QemuGate.result(ran, notes: run.notes)
  end
)
