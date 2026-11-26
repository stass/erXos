# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require_relative '../production_image'
require_relative '../qemu_gate'

# The production image booted with erx.trace=0 at one CPU under HVF
# (docs/design-fiasco.md, "The kernel's trace rings"; Erx::ProductionImage::Run#trace_off):
# the kernel prints no rings line, the boot reaches the shell, and a read of a kernel ring
# answers unsupported. Run raises on the first disagreement, which the gate reports as this
# suite failing. check_qemu builds the kernel before any suite runs, so this suite does not.
count = 1
Erx::QemuGate.declare_suite(
  cells: Erx::QemuGate.suite_cells([count]),
  run: lambda do |context|
    run = Erx::ProductionImage::Run.new(root: context.root)
    ran = run.trace_off(accel: Erx::QemuGate::SUITE_ACCELERATOR, count: count, jobs: context.jobs, build: false)
    Erx::QemuGate.result(ran.transform_values { 'passed' })
  end
)
