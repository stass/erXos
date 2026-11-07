# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require_relative '../production_image'
require_relative '../qemu_gate'

# erx:trace on the production image at four CPUs under HVF (docs/design-stopgap.md,
# Verification, "Trace on four CPUs"; Erx::ProductionImage::Run#trace): the kernel row
# unsupported, a backend park and a wake of the same slot, and a test workload's erts in
# not late, with every erts line naming the workload (trace_problems). Run raises on the
# first disagreement, which the gate reports as this suite failing. check_qemu builds the
# kernel before any suite runs, so this suite does not.
count = 4
Erx::QemuGate.declare_suite(
  cells: Erx::QemuGate.suite_cells([count]),
  run: lambda do |context|
    run = Erx::ProductionImage::Run.new(root: context.root)
    ran = run.trace(accel: Erx::QemuGate::SUITE_ACCELERATOR, count: count, jobs: context.jobs, build: false)
    Erx::QemuGate.result(ran.transform_values { 'passed' })
  end
)
