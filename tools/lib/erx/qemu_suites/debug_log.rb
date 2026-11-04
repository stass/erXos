# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require_relative '../debug_log_probe'
require_relative '../qemu_gate'

# The first kernel call on the stopgap, end to end: the probe's transcript on
# the real trap path under each accelerator and CPU count must equal the
# hosted backend's and the expected one (tools/lib/erx/debug_log_probe.rb).
# DebugLogProbe::Run raises on the first disagreement, which the gate reports
# as this suite failing. An accelerator the host lacks leaves its cells
# not_run.
# check_qemu builds the kernel before any suite runs, so this suite does not.
Erx::QemuGate.declare_suite(
  run: lambda do |context|
    cpus = [1, 4]
    ran = if context.runnable.empty?
            {}
          else
            Erx::DebugLogProbe::Run.new(root: context.root)
                                   .call(accels: context.runnable, cpus: cpus, jobs: context.jobs, build: false)
                                   .transform_values { 'passed' }
          end
    skipped = context.missing.product(cpus).to_h { |accel, count| ["#{accel}-#{count}cpu", 'not_run'] }
    notes = context.missing.map { |accel| "#{accel} is not offered by this host's QEMU" }
    Erx::QemuGate.result(ran.merge(skipped), notes: notes)
  end
)
