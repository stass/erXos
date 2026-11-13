# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require_relative '../apps'
require_relative '../qemu_gate'

# The start table on the development machine, under HVF at each CPU count
# (tools/lib/erx/apps.rb): an enabled start row boots its app's session with no login,
# holding only its template's grant, keeps it within its intensity and leaves the row
# down past it; a row left off and a manifest with no start row start no session but
# root's console login; `service` refuses a name the manifest does not declare; and
# `service disable` and `enable` change rc.conf on /data, so each holds across a reboot.
# Run raises on the first disagreement, which the gate reports as this suite failing.
# check_qemu builds the kernel before any suite runs, so this suite does not. Every boot
# has a disk, which a remote boot does not take (Qemu#run), so its multi-CPU cells stay
# here and it declares no offload (QemuGate::Suite).
cpus = [1, 4]
Erx::QemuGate.declare_suite(
  cells: Erx::Apps::Run.cells(cpus),
  run: lambda do |context|
    ran = Erx::Apps::Run.new(root: context.root).call(cpus: cpus, jobs: context.jobs, build: false,
                                                      placement: context.placement)
    Erx::QemuGate.result(ran)
  end
)
