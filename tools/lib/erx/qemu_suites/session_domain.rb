# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require_relative '../qemu_gate'
require_relative '../session_domain'

# Root's session domain on the development machine, under HVF at each CPU count
# (tools/lib/erx/session_domain.rb): root_1, the session the console's login starts at
# boot, takes the UART; its shells answer, a 64 KiB burst survives the menu toggling,
# halt(3) ends it with one line and the login's next session takes the line, and from
# the system shell exit(DomainPid, kill) ends that one the same way. Run raises on the
# first disagreement, which the gate reports as this suite failing. check_qemu builds the
# kernel before any suite runs, so this suite does not.
cpus = [1, 4]
Erx::QemuGate.declare_suite(
  cells: Erx::SessionDomain::Run.cells(cpus),
  run: lambda do |context|
    ran = Erx::SessionDomain::Run.new(root: context.root).call(cpus: cpus, jobs: context.jobs, build: false,
                                                                     placement: context.placement)
    Erx::QemuGate.result(ran)
  end
)
