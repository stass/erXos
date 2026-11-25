# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require_relative 'bench_measurement'
require_relative 'bench_suite'
require_relative 'native_bench'

module Erx
  # bench/peer/erx_peer_bench.c, the POSIX counterparts of the native bench guest's cells
  # that FreeBSD and Linux compile with their own compiler (docs/design-bench.md, "Other
  # systems on the same Raspberry Pi 4"): the flags its build
  # takes from the one source of each value, and what one of its runs asks, so its lines go
  # through BenchMeasurement.boot as a native boot's do.
  module PeerBench
    # A run of one of these times the benchmark's cells of the boot named.
    BOOTS = { 'nullcall' => 'native', 'vm' => 'native', 'wake' => 'native', 'sched' => 'native',
              'xdomain' => 'xdomain' }.freeze
    # A run ends by SIGALRM this long after it starts, so a stalled side ends it.
    RUN_DEADLINE_SECONDS = 300

    module_function

    # The -D flags of the source's build: the landing profiles' sizes and the xdomain
    # cells' parameters, as their declarations give them, and the run's deadline.
    def flags
      bytes, encoded = xdomain_parameters.values_at('bytes', 'encoded')
      [*NativeBench.profile_flags, "-DERX_PEER_XDOMAIN_BYTES=#{bytes}u",
       "-DERX_PEER_XDOMAIN_ENCODED=#{encoded}u", "-DERX_PEER_RUN_DEADLINE_S=#{RUN_DEADLINE_SECONDS}u"].freeze
    end

    # What a run of benchmark name on a machine of cpus CPUs, reading clock, asks: the
    # benchmark's cells in its boot, and the pair a native-set run calibrates, CPU 0 and
    # the last, on more than one CPU.
    def asked(name, cpus:, clock:)
      boot = BOOTS.fetch(name) { raise Error, "bench: #{name} has no peer counterpart" }
      pairs = boot == 'native' && cpus > 1 ? [[0, cpus - 1]] : []
      BenchMeasurement::Asked.new(benchmarks: [NativeBench.wanted(BenchSuite.benchmark(name), boot: boot)],
                                  clock: clock, pairs: pairs)
    end

    def xdomain_parameters
      cells = BenchSuite.benchmark('xdomain').landing.fetch('xdomain').map(&:parameters).uniq
      raise Error, 'bench: the xdomain cells disagree on their parameters' unless cells.one?

      cells.first
    end

    private_class_method :xdomain_parameters
  end
end
