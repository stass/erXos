# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require_relative '../bench_suite'
require_relative '../etf'

# One message, one domain to another (docs/design-bench.md, "5. `xdomain`: one message,
# one domain to another"): a funnel, lane or facet change that adds a copy, a pass or a
# wake to a small request across domains, against the same exchange inside one domain.
# Each cell's parameters are the request's binary size and its encoded size, the bytes
# term_to_binary makes of {echo, B}, which the echo facet's 512-byte max_request bounds
# (Erx::SystemDomain::Regrant::FACET_LIMITS). xdomain-throughput and xdomain-stall need
# what the echo fixture lacks and are designed with G5's runs.
operation = Erx::BenchSuite::Operation
cell = Erx::BenchSuite::LandingCell
etf = Erx::Etf
bytes = 64
request = etf::Tuple.new(elements: [etf::Atom.new(name: 'echo'), ("\xa5".b * bytes).freeze])
parameters = { 'bytes' => bytes, 'encoded' => etf.encode(request).bytesize }
Erx::BenchSuite.declare_benchmark(
  operations: [
    operation.new(name: 'local-rtt', profile: 'fast', result: 'the reply equals the request'),
    operation.new(name: 'xdomain-pingpong', profile: 'fast', result: 'the reply equals the request')
  ],
  landing: {
    'xdomain' => [
      cell.new(operation: 'local-rtt', load: 'idle', placement: 'runtime', parameters: parameters),
      cell.new(operation: 'xdomain-pingpong', load: 'idle', placement: 'runtime', parameters: parameters)
    ]
  }
)
