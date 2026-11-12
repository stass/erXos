# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require_relative '../qemu_gate'
require_relative '../raspi4b_shell'

# The serial shell on QEMU's raspi4b model under TCG (tools/lib/erx/raspi4b_shell.rb): the
# Raspberry Pi 4's development image boots through QEMU's loader to root's session on the
# mini UART, which answers a sum, a rubbed-out line and a long output and writes a log
# record escaped, at four CPUs, and halts the machine; and, seeded, a tree with one CPU's
# node removed shows three. The suite builds the Pi's own inputs, the board's bootstrap,
# BL31, the model's tree and the image, since check_qemu builds only the kernel. Every cell
# needs the loader's boot stub, which a remote boot does not take (Qemu#run), so it
# declares no offload (QemuGate::Suite).
Erx::QemuGate.declare_suite(
  cells: Erx::Raspi4bShell::CELLS,
  run: lambda do |context|
    ran = Erx::Raspi4bShell.new(root: context.root).call(jobs: context.jobs)
    Erx::QemuGate.result(ran.transform_values { 'passed' })
  end
)
