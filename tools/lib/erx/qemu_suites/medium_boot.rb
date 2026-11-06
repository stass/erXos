# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require_relative '../medium_boot'
require_relative '../qemu_gate'

# The production image boots from its release medium, the harness playing the firmware
# (tools/lib/erx/medium_boot.rb): the slot parser reads the boot-selection record the
# packer wrote, the committed slot's bootable file boots with the medium attached, and
# the kernel reports the boot value the harness wrote into /chosen before the release
# reaches the shell, under HVF at each CPU count. Run raises on the first disagreement,
# which the gate reports as this suite failing. check_qemu builds the kernel before any
# suite runs, so this suite does not.
cpus = [1, 4]
Erx::QemuGate.declare_suite(
  cells: Erx::QemuGate.suite_cells(cpus),
  run: lambda do |context|
    ran = Erx::MediumBoot::Run.new(root: context.root).call(cpus: cpus, jobs: context.jobs, build: false)
    Erx::QemuGate.result(ran)
  end
)
