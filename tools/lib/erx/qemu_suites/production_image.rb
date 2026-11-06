# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require_relative '../production_image'
require_relative '../qemu_gate'

# The production image, packed through the manifest check, boots to where ERTS starts and
# ends the machine, and refuses a machine too small for its manifest, under HVF at each CPU
# count (tools/lib/erx/production_image.rb). Under TCG it has the two things only TCG does:
# one boot to the shell at one CPU, and the deterministic-mode transcript (`erx.det=1`).
# Run raises on the first disagreement, which the gate reports as this suite failing. An
# accelerator the host lacks leaves its cells not_run. check_qemu builds the kernel before
# any suite runs, so this suite does not.
Erx::QemuGate.declare_suite(
  run: lambda do |context|
    cpus = [1, 4]
    smoke = [Erx::QemuGate::SMOKE_ACCELERATOR] & context.available
    ran = if context.runnable.empty? && smoke.empty?
            {}
          else
            Erx::ProductionImage::Run.new(root: context.root)
                                     .call(accels: context.runnable, cpus: cpus, jobs: context.jobs, build: false,
                                           smoke_accels: smoke)
                                     .transform_values { 'passed' }
          end
    skipped = context.missing.product(cpus).to_h { |accel, count| ["#{accel}-#{count}cpu", 'not_run'] }
    if smoke.empty?
      skipped["#{Erx::QemuGate::SMOKE_ACCELERATOR}-1cpu"] = 'not_run'
    end
    notes = (context.missing + ([Erx::QemuGate::SMOKE_ACCELERATOR] - smoke)).map do |accel|
      "#{accel} is not offered by this host's QEMU"
    end
    Erx::QemuGate.result(ran.merge(skipped), notes: notes)
  end
)
