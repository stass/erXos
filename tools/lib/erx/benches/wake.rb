# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require_relative '../bench_suite'

# How late a waiting thread runs (docs/design-bench.md,
# "1. `wake`: how late a waiting thread runs"). A lost wake, a wake that waits behind other work at its level, whether a timed wait ends only at a tick
# (the phase sweep shows it), and a doorbell path that grows a request to the root.
# gpio-edge, on the Raspberry Pi 4 only, is declared with its responders.
operation = Erx::BenchSuite::Operation
cell = Erx::BenchSuite::LandingCell
# What FreeBSD and Linux run, erx_peer_bench's POSIX counterparts (docs/design-bench.md,
# "Counterparts"); L4Re's ipcbench has none for a wake.
posix = ->(line) { { 'freebsd' => line, 'linux' => line } }
condition_wake = 'pthread_cond_timedwait woken by a signal once /proc shows B asleep'
Erx::BenchSuite.declare_benchmark(
  operations: [
    operation.new(name: 'park-deadline', profile: 'periodic',
                  result: 'ERX_ETIMEDOUT, not before its deadline',
                  counterparts: posix.call('clock_nanosleep on CLOCK_MONOTONIC with TIMER_ABSTIME, period 1 ms')),
    operation.new(name: 'wake-same-cpu', profile: 'fast', handshake: true,
                  result: "B's park returns ERX_OK; ERX_ETIMEDOUT is a lost wake",
                  counterparts: posix.call("#{condition_wake}, both threads on one CPU")),
    operation.new(name: 'wake-cross-cpu', profile: 'fast', handshake: true,
                  result: "B's park returns ERX_OK; ERX_ETIMEDOUT is a lost wake",
                  counterparts: posix.call("#{condition_wake}, A on another CPU")),
    operation.new(name: 'trigger-take', profile: 'fast', handshake: true,
                  result: 'the label the bind gave, once per fire'),
    operation.new(name: 'erlang-timer', profile: 'periodic', sweep: false,
                  result: 'one message per deadline, none before it')
  ],
  landing: {
    'native' => [
      cell.new(operation: 'wake-same-cpu', load: 'idle', placement: 'same-cpu', parameters: {}),
      cell.new(operation: 'wake-cross-cpu', load: 'idle', placement: 'cross-cpu', parameters: {}),
      cell.new(operation: 'trigger-take', load: 'idle', placement: 'same-cpu', parameters: {}),
      cell.new(operation: 'park-deadline', load: 'idle', placement: 'service-cpu', parameters: {})
    ],
    'xdomain' => [
      cell.new(operation: 'erlang-timer', load: 'idle', placement: 'runtime', parameters: { 'priority' => 'normal' })
    ]
  }
)
