# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require_relative '../debug_log_probe'
require_relative '../qemu_gate'

# The first kernel call on the stopgap, end to end: the probe's transcript on
# the real trap path under HVF at each CPU count must equal the
# hosted backend's and the expected one (tools/lib/erx/debug_log_probe.rb).
# DebugLogProbe::Run raises on the first disagreement, which the gate reports
# as this suite failing.
# check_qemu builds the kernel before any suite runs, so this suite does not.
cpus = [1, 4]
Erx::QemuGate.declare_suite(
  cells: Erx::QemuGate.suite_cells(cpus),
  run: lambda do |context|
    run = Erx::DebugLogProbe::Run.new(root: context.root)
    ran = run.call(accels: [Erx::QemuGate::SUITE_ACCELERATOR], cpus: cpus, jobs: context.jobs, build: false)
    Erx::QemuGate.result(ran.transform_values { 'passed' })
  end
)
