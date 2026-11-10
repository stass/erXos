# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require_relative '../native_boot'
require_relative '../qemu_gate'

# The boot image reaches the native root task, which reports its record on the
# console and ends the machine, under HVF at each CPU count
# (tools/lib/erx/native_boot.rb). NativeBoot::Run raises on the first
# disagreement, which the gate reports as this suite failing.
# check_qemu builds the kernel before any suite runs, so this suite does not.
cpus = [1, 4]
Erx::QemuGate.declare_suite(
  cells: Erx::QemuGate.suite_cells(cpus),
  run: lambda do |context|
    run = Erx::NativeBoot::Run.new(root: context.root)
    ran = run.call(accels: [Erx::QemuGate::SUITE_ACCELERATOR], cpus: cpus, jobs: context.jobs, build: false,
                   placement: context.placement)
    Erx::QemuGate.result(ran.transform_values { 'passed' })
  end
)
