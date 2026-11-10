# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require_relative '../qemu_gate'
require_relative '../system_domain'

# The system domain with ERTS domains running under it, under HVF at each CPU count
# (tools/lib/erx/system_domain.rb): service_kill kills the domain service while its
# configured domain runs and sees the runtime end with its slogan and the machine end by
# itself. Run raises on the first disagreement, which the gate reports as this suite
# failing. check_qemu builds the kernel before any suite runs, so this suite does not.
cpus = [1, 4]
Erx::QemuGate.declare_suite(
  cells: Erx::SystemDomain::Run.cells(cpus),
  run: lambda do |context|
    ran = Erx::SystemDomain::Run.new(root: context.root).call(cpus: cpus, jobs: context.jobs, build: false)
    Erx::QemuGate.result(ran)
  end
)
