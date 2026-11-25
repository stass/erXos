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
# What L4Re runs, ipcbench's programs (docs/design-bench.md, "Counterparts"), read through
# its facts record; Erx::Ipcbench reads their lines. What Linux runs, erx_peer_bench's POSIX
# counterparts; it has none for root-same-space.
Erx::BenchSuite.declare_benchmark(
  operations: [
    operation.new(name: 'root-same-space', profile: 'fast', result: refused,
                  counterparts: { 'l4re' => 'ipcbench: two threads of one task; a blocking call with an empty message ' \
                                          'to a responder already waiting in reply-and-wait' }),
    operation.new(name: 'root-cross-space', profile: 'fast', result: refused,
                  counterparts: { 'l4re' => 'ipcclient and ipcserver: a blocking call with an empty message ' \
                                          'between two tasks, the responder waiting in reply-and-wait',
                                 'linux' => 'two processes: an 8-byte request and an 8-byte reply over a pair of ' \
                                            'pipes, each read blocking' }),
    operation.new(name: 'kernel', profile: 'fast',
                  result: "an IPC call to the empty slot 0 answers Fiasco's L4_IPC_ENOT_EXISTENT",
                  counterparts: { 'l4re' => "syscallbench: an IPC call to the caller's own thread capability " \
                                          'whose thread-control operation returns early',
                                 'linux' => 'getppid' })
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
