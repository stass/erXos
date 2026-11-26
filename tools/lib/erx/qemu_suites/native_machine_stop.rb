# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require_relative '../native_machine_stop'
require_relative '../qemu_gate'

# A panic on CPU 2 of four stops the machine: the crash record names CPU 2 as
# the leader and the other three as stopped (tools/lib/erx/native_machine_stop.rb).
# The test kernel is built here, beside the real one check_qemu builds first.
cpus = [Erx::NativeMachineStop::CPUS]
Erx::QemuGate.declare_suite(
  cells: Erx::QemuGate.suite_cells(cpus),
  run: lambda do |context|
    Erx::NativeMachineStop::Run.new(root: context.root)
                               .call(accel: Erx::QemuGate::SUITE_ACCELERATOR, jobs: context.jobs, build: false)
    Erx::QemuGate.result(Erx::QemuGate.suite_cells(cpus).to_h { |cell| [cell, 'passed'] })
  end
)
