# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require_relative '../qemu_gate'
require_relative '../programs'

# Native programs of root's session, under HVF at each CPU count
# (tools/lib/erx/programs.rb), booted from a test image whose session release holds
# test/guest/programs/ and erx-lvgl in bin/: at root_1's Erlang shell, erx_program:start/1
# runs each program of Programs' case list, from exit42, which reports
# {exit_status, 42}, to erx-lvgl, which ends with status 1 when it finds no window
# buffer to map. The shell answers node() after each. Run raises on the first disagreement, which the gate
# reports as this suite failing. check_qemu builds the kernel before any suite runs, so
# this suite does not. Its multi-CPU cell has not been run under TCG on a second host,
# so it declares no offload (QemuGate::Suite).
cpus = [1, 4]
Erx::QemuGate.declare_suite(
  cells: Erx::Programs::Run.cells(cpus),
  run: lambda do |context|
    ran = Erx::Programs::Run.new(root: context.root).call(cpus: cpus, jobs: context.jobs, build: false,
                                                           placement: context.placement)
    Erx::QemuGate.result(ran)
  end
)
