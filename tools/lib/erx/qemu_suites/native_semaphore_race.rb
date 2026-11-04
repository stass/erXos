# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require_relative '../native_semaphore_race'
require_relative '../qemu_gate'

# An up across CPUs racing a down's timeout, on a test kernel that holds the race open
# (tools/lib/erx/native_semaphore_race.rb). Two CPUs at least, so 4 only. Run raises on the
# first disagreement, which the gate reports as this suite failing. An accelerator the
# host lacks leaves its cell not_run. check_qemu builds the real kernel before any suite
# runs, so this suite builds only its test kernel.
Erx::QemuGate.declare_suite(
  run: lambda do |context|
    cpus = [4]
    ran = if context.runnable.empty?
            {}
          else
            Erx::NativeSemaphoreRace::Run.new(root: context.root)
                                         .call(accels: context.runnable, cpus: cpus, jobs: context.jobs, build: false)
                                         .transform_values { 'passed' }
          end
    skipped = context.missing.product(cpus).to_h { |accel, count| ["#{accel}-#{count}cpu", 'not_run'] }
    notes = context.missing.map { |accel| "#{accel} is not offered by this host's QEMU" }
    Erx::QemuGate.result(ran.merge(skipped), notes: notes)
  end
)
