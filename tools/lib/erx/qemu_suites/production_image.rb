# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require_relative '../production_image'
require_relative '../qemu_gate'

# The production image, packed through the manifest check, boots to where ERTS starts and
# ends the machine, and refuses a machine too small for its manifest, under HVF at each CPU
# count (tools/lib/erx/production_image.rb). Under TCG it has the two things only TCG does:
# one boot to the shell at one CPU of a machine with one UART and no host link, as the
# website's is, and the deterministic-mode transcript (`erx.det=1`),
# each a cell of its own, so a run that skips either leaves the suite incomplete. Run raises
# on the first disagreement, which the gate reports as this suite failing. check_qemu builds
# the kernel before any suite runs, so this suite does not.
cpus = [1, 4]
Erx::QemuGate.declare_suite(
  cells: [*Erx::QemuGate.suite_cells(cpus), *Erx::ProductionImage::Run::SMOKE_CELLS],
  run: lambda do |context|
    run = Erx::ProductionImage::Run.new(root: context.root)
    ran = run.call(accels: [Erx::QemuGate::SUITE_ACCELERATOR], cpus: cpus, jobs: context.jobs, build: false, smoke: true)
    Erx::QemuGate.result(ran.transform_values { 'passed' })
  end
)
