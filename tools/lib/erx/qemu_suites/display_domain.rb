# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require_relative '../display_domain'
require_relative '../qemu_gate'

# The display domain on QEMU virt under HVF (tools/lib/erx/display_domain.rb): the
# suite's own manifest (DisplayDomain.manifest) boots with a virtio-gpu attached, the display domain's driver brings it
# up, the display's session (erx_pattern_test) presents a pattern in a window, and the
# screen read through QMP equals the reference picture. HVF at one CPU is its one cell. Its boot carries a display, which no
# remote host serves, so it does not declare offload. check_qemu builds the kernel before
# any suite runs, so this suite does not.
cells = Erx::QemuGate.suite_cells([1])
Erx::QemuGate.declare_suite(
  cells: cells,
  run: lambda do |context|
    ran = Erx::DisplayDomain::Run.new(root: context.root).call(cpus: [1], jobs: context.jobs, build: false,
                                                               placement: context.placement)
    Erx::QemuGate.result(ran)
  end
)
