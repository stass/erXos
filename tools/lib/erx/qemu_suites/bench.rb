# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require_relative '../bench_suite'
require_relative '../linux_erlang_guest'
require_relative '../qemu_gate'

# The landing matrix of the benchmarks under HVF (docs/design-bench.md, "The gates"): its
# cells are each boot's benchmarks (Erx::BenchSuite.suite_cells), each the worst of its
# benchmark cells' statuses, and Linux's Erlang guest's boot of the xdomain benchmark
# (Erx::LinuxErlangGuest::Landing), not run without the oracle's install export. It
# declares no offload, so its cells never move to a TCG host.
Erx::QemuGate.declare_suite(
  cells: Erx::BenchSuite.suite_cells,
  run: lambda do |context|
    ran = Erx::BenchSuite.run(context, linux_erlang: Erx::LinuxErlangGuest::Landing.new(root: context.root))
    Erx::QemuGate.result(ran.fetch(:cells), notes: ran.fetch(:notes))
  end
)
