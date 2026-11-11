# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require_relative '../device_give'
require_relative '../qemu_gate'

# A configured domain's device, given again at its restart, under HVF at each CPU count
# (tools/lib/erx/device_give.rb): the domain holding the platform's spare unit reads the
# transport's magic, is halted, and reads it again under its new id. Run raises on the
# first disagreement, which the gate reports as this suite failing. check_qemu builds the
# kernel before any suite runs, so this suite does not. Its 4-CPU cell boots the whole
# production image and two ERTS domains, as system_domain's does, so it declares offload
# (QemuGate::Suite).
cpus = [1, 4]
Erx::QemuGate.declare_suite(
  cells: Erx::QemuGate.suite_cells(cpus),
  offload: true,
  run: lambda do |context|
    ran = Erx::DeviceGive::Run.new(root: context.root).call(cpus: cpus, jobs: context.jobs, build: false,
                                                            placement: context.placement)
    Erx::QemuGate.result(ran)
  end
)
