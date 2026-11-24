# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require_relative '../bench_suite'

# The decoder-refusal round trip (docs/design-bench.md, "3. `nullcall`: the decoder-refusal
# round trip"): growth of the root service's receive, decode and reply path, a mitigation
# added to every entry, and Fiasco's IPC slowing under a configuration change. kernel is
# the cheapest call Fiasco answers alone, chosen from its source: an IPC to an empty
# capability slot, which sys_ipc_wrapper (kernel/src/kern/syscalls.cpp) answers from the
# capability lookup without reaching an object.
operation = Erx::BenchSuite::Operation
cell = Erx::BenchSuite::LandingCell
refused = "ERX_EINVAL, and the caller's count of refusals rises by each call (erx_fiasco_test_refused)"
Erx::BenchSuite.declare_benchmark(
  operations: [
    operation.new(name: 'root-same-space', profile: 'fast', result: refused),
    operation.new(name: 'root-cross-space', profile: 'fast', result: refused),
    operation.new(name: 'kernel', profile: 'fast',
                  result: "an IPC call to the empty slot 0 answers Fiasco's L4_IPC_ENOT_EXISTENT")
  ],
  landing: {
    'native' => [
      cell.new(operation: 'root-same-space', load: 'idle', placement: 'service-cpu', parameters: {}),
      cell.new(operation: 'root-same-space', load: 'idle', placement: 'other-cpu', parameters: {}),
      cell.new(operation: 'root-cross-space', load: 'idle', placement: 'service-cpu', parameters: {}),
      cell.new(operation: 'root-cross-space', load: 'idle', placement: 'other-cpu', parameters: {}),
      cell.new(operation: 'kernel', load: 'idle', placement: 'same-cpu', parameters: {})
    ]
  }
)
