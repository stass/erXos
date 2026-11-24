# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require_relative '../bench_suite'

# What memory costs (docs/design-bench.md, "4. `vm`: what memory costs"): a commit or a
# protect whose plan walks more than it should, a page charged or zeroed twice, and the
# cost the root as pager adds over a kernel's map. Each cell is one page, timed from a test
# task; a status of ERX_OK alone could pass a call that did nothing, so each timed loop is
# followed by native_memory's check for that call, and protect also by a write to the
# read-only page that must fault.
operation = Erx::BenchSuite::Operation
cell = Erx::BenchSuite::LandingCell
checked = 'ERX_OK, and the untimed check for the call'
Erx::BenchSuite.declare_benchmark(
  operations: [
    operation.new(name: 'reserve', profile: 'fast', result: 'ERX_OK; the free page count unchanged after the release'),
    operation.new(name: 'commit', profile: 'fast', result: "#{checked}: the committed page reads zero"),
    operation.new(name: 'touch', profile: 'fast',
                  result: 'the first write completes and reads back; on Fiasco the commit has mapped the page already (FD7)'),
    operation.new(name: 'protect', profile: 'fast',
                  result: "#{checked}: a written page reads back after read-only and back, and a write to a read-only page faults at it"),
    operation.new(name: 'decommit', profile: 'fast', result: "#{checked}: the page committed again reads zero"),
    operation.new(name: 'release', profile: 'fast', result: 'ERX_OK; the free page count back to what it was')
  ],
  landing: {
    'native' => %w[reserve commit touch protect decommit release].map do |name|
      cell.new(operation: name, load: 'idle', placement: 'service-cpu', parameters: {})
    end
  }
)
