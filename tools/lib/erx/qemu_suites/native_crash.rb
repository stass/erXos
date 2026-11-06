# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require_relative '../native_crash'
require_relative '../qemu_gate'

# A root thread's fault ends the machine with a crash record that is read back,
# under HVF at each CPU count (tools/lib/erx/native_crash.rb). Run raises on
# the first disagreement, which the gate reports as this suite failing. check_qemu builds the kernel
# before any suite runs, so this suite does not.
cpus = [1, 4]
Erx::QemuGate.declare_suite(
  cells: Erx::QemuGate.suite_cells(cpus),
  run: lambda do |context|
    run = Erx::NativeCrash::Run.new(root: context.root)
    ran = run.call(accels: [Erx::QemuGate::SUITE_ACCELERATOR], cpus: cpus, jobs: context.jobs, build: false)
    Erx::QemuGate.result(ran.transform_values { 'passed' })
  end
)
