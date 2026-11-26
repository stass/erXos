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
              'xdomain' => 'xdomain', 'posix' => 'posix' }.freeze
    # The boots whose runs calibrate CPU 0 against the last on more than one CPU; an
    # xdomain run is not pinned.
    CALIBRATED = %w[native posix].freeze
    # The program's one C file, which every system's build compiles.
    SOURCE = 'bench/peer/erx_peer_bench.c'
    # A run ends by SIGALRM this long after it starts under HVF or on a board, so a stalled
    # side ends it (docs/design-bench.md, "The program's deadline").
    RUN_DEADLINE_SECONDS = 300
    # How many times RUN_DEADLINE_SECONDS a run is given under each accelerator: TCG
    # translates every instruction, so a run that takes most of the base deadline under
    # HVF takes about three times as long under TCG. 'native' is a board.
    DEADLINE_FACTORS = { 'native' => 1, 'hvf' => 1, 'tcg' => 3 }.freeze

    module_function

    # Whether a run of benchmark name binds its threads to CPUs, given pinned (false for a
    # posix run told "unpinned"): every run but an xdomain run's pins.
    def pins?(name, pinned: true) = BOOTS.fetch(name) != 'xdomain' && pinned

    # The seconds a run under accel (a key of DEADLINE_FACTORS) is given before its alarm.
    def run_deadline(accel)
      RUN_DEADLINE_SECONDS * DEADLINE_FACTORS.fetch(accel) { raise Error, "bench: no run deadline under #{accel}" }
    end

    # The -D flags of the source's build for runs under accel: the landing profiles' sizes
    # and the xdomain cells' parameters, as their declarations give them, and the run's
    # deadline under accel.
    def flags(accel:)
      bytes, encoded = xdomain_parameters.values_at('bytes', 'encoded')
      [*NativeBench.profile_flags, "-DERX_PEER_XDOMAIN_BYTES=#{bytes}u",
       "-DERX_PEER_XDOMAIN_ENCODED=#{encoded}u", "-DERX_PEER_RUN_DEADLINE_S=#{run_deadline(accel)}u"].freeze
    end

    # The program's arguments for a run of benchmark name on cpus CPUs: a posix run is given
    # the count, which on erXos the program cannot ask the system for (docs/design-bench.md,
    # "The program's clock and placement"); a native-set or xdomain run asks. A posix run
    # on a system whose placement call is refused (pinned false, Genode's) is also told
    # "unpinned": it pins nothing and reports every cell that times a peer thread
    # unsupported, on the same CPU or across CPUs.
    def arguments(name, cpus:, pinned: true)
      return [name, cpus.to_s, *(pinned ? [] : ['unpinned'])] if BOOTS.fetch(name) == 'posix'
      raise Error, "bench: only a posix run is ever unpinned, not #{name}" unless pinned

      [name]
    end

    # What a run of benchmark name on a machine of cpus CPUs, reading clock, asks: the
    # benchmark's cells in its boot, and the pair a native-set or posix run calibrates,
    # CPU 0 and the last, on more than one CPU when its threads are pinned.
    def asked(name, cpus:, clock:, pinned: true)
      boot = BOOTS.fetch(name) { raise Error, "bench: #{name} has no peer counterpart" }
      pairs = CALIBRATED.include?(boot) && cpus > 1 && pinned ? [[0, cpus - 1]] : []
      BenchMeasurement::Asked.new(benchmarks: [NativeBench.wanted(BenchSuite.benchmark(name), boot: boot)],
                                  clock: clock, pairs: pairs)
    end

    # The first line of compiler's own report of its version: how every system's record
    # names the compiler that built the program, so the records compare.
    def compiler_version(runner, compiler)
      raise Error, 'bench: set ERX_CLANG to the LLVM clang that builds erx_peer_bench' if compiler.to_s.empty?

      log = runner.run([compiler, '--version'], name: 'peer-bench-cc-version', deadline: 30).fetch('log')
      File.binread(log, 4096).lines.first.to_s.strip
    end

    def xdomain_parameters
      cells = BenchSuite.benchmark('xdomain').landing.fetch('xdomain').map(&:parameters).uniq
      raise Error, 'bench: the xdomain cells disagree on their parameters' unless cells.one?

      cells.first
    end

    private_class_method :xdomain_parameters
  end
end
