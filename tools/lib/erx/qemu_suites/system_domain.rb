# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require_relative '../qemu_gate'
require_relative '../system_domain'

# The system domain with ERTS domains running under it, under HVF at each CPU count
# (tools/lib/erx/system_domain.rb): service_kill ends one configured domain's system side
# with another domain's {domain_down, D2, x}, which its watcher sees as noconnection, and
# the other by having it kill its agent behind a burst it published, which halts it with
# status 69; the burst arrives whole, then the exit (the lane driver's finish), and the end fires
# {domain_down, D, {halt, 69}} on its watcher's link, monitor and pending spawn, while
# library calls into it (gen, erpc, rpc, the spawn family) keep stock's node-level
# results; before those ends, the two domains' introduced connection goes down from one
# side by erlang:disconnect_node/1, behind a burst only the other side's finish delivers,
# and by a malformed frame, each with noconnection at both ends and its objects deleted
# before the pair is introduced again; then it kills the domain service and sees the
# runtime end with its slogan and the
# machine end by itself. Run raises on the first disagreement, which the gate reports as this suite
# failing. check_qemu builds the kernel before any suite runs, so this suite does not.
cpus = [1, 4]
Erx::QemuGate.declare_suite(
  cells: Erx::SystemDomain::Run.cells(cpus),
  run: lambda do |context|
    ran = Erx::SystemDomain::Run.new(root: context.root).call(cpus: cpus, jobs: context.jobs, build: false,
                                                                    placement: context.placement)
    Erx::QemuGate.result(ran)
  end
)
