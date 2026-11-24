# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true
require_relative '../bench_suite'

# How a CPU is shared (docs/design-bench.md, "2. `sched`: how a CPU is shared"): a slice
# that reverts to Fiasco's 10 ms default, a thread starved at its level. share-equal's
# recording spinners are one test task's, all on the last CPU, which is not the root
# service's; each window's lines say how each thread shared it (docs/design-bench.md, "A
# sustained cell").
operation = Erx::BenchSuite::Operation
cell = Erx::BenchSuite::LandingCell
Erx::BenchSuite.declare_benchmark(
  operations: [
    operation.new(name: 'share-equal', profile: 'sustained', result: 'every thread runs in each window')
  ],
  landing: {
    'native' => [
      cell.new(operation: 'share-equal', load: 'idle', placement: 'other-cpu',
               parameters: { 'threads' => 4, 'window-ms' => 1000 })
    ]
  }
)
