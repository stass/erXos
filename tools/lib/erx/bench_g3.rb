# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'json'
require 'time'
require_relative 'bench'
require_relative 'bench_guest'

module Erx
  # Gate G3's measurements (docs/plan.md, M3): W1 of E-S1, the footprint at the idle shell
  # and boot time to the shell, on erXos under QEMU and on stock OTP on this host, in one
  # report. The guest runs under the one accelerator asked for, and the stock runs use the
  # iterations and samples that accelerator's guest ran, so every pair of numbers shares a
  # workload. TCG and HVF numbers are two reports, never compared with each other.
  class BenchG3
    # The ERTS build's flags, as the target's cross-compile file states them.
    CROSS_FILE = 'otp/xcomp/erl-xcomp-aarch64-unknown-erxos.conf'
    FLAG_VARIABLES = %w[ERX_TARGET_FLAGS CFLAGS CXXFLAGS LDFLAGS].freeze

    def initialize(root:, runner: nil)
      @root = File.realpath(root)
      @runner = runner || Runner.new(owner_root: @root, log_dir: File.join(@root, 'build/logs'))
      @bench = Bench.new(root: @root, runner: @runner)
    end

    # Runs the guest, then the stock side, and writes build/bench/g3-<accel>-*/result.json.
    def run(accel:, flavour: 'emu', jobs: 4, image: nil)
      plan = BenchGuest::PLANS.fetch(accel) { raise Error, "no G3 plan for accelerator #{accel}" }
      guest = BenchGuest.run(root: @root, runner: @runner, plan: plan, beam: @bench.beam(flavour: flavour),
                                                             image: image, jobs: jobs)
      stock = BenchGuest::WORKLOADS.to_h do |workload|
        report = @bench.run("otp-#{workload}", flavour: flavour, samples: plan.samples,
                                               iterations: BenchGuest.iterations_for(workload, plan))
        [workload, report]
      end
      report = describe(plan: plan, flavour: flavour, guest: guest, stock: stock, footprint: @bench.footprint(flavour: flavour))
      write(report, accel)
    end

    # The medians of one workload's samples on each side and their ratio, which is the guest
    # over the stock: above 1 means the guest takes longer.
    def self.compare(guest_measurement, stock_measurement)
      guest = median(guest_measurement.fetch('ns_per_operation'))
      stock = median(stock_measurement.fetch('ns_per_operation'))
      { 'guest_ns' => guest, 'stock_ns' => stock, 'guest_over_stock' => stock.zero? ? nil : guest / stock }
    end

    def self.median(values)
      sorted = values.sort
      middle = sorted.size / 2
      sorted.size.odd? ? sorted.fetch(middle) : (sorted.fetch(middle - 1) + sorted.fetch(middle)) / 2.0
    end

    private

    def describe(plan:, flavour:, guest:, stock:, footprint:)
      by_name = guest.fetch('measurements').to_h { |measurement| [measurement.fetch('workload'), measurement] }
      comparison = BenchGuest::WORKLOADS.to_h do |workload|
        [workload, self.class.compare(by_name.fetch(workload), stock.fetch(workload).fetch('measurement'))]
      end
      { 'kind' => 'g3', 'date' => Time.now.utc.iso8601, 'host' => @bench.host_description,
        'accelerator' => plan.accel, 'qemu' => guest.fetch('qemu_version'),
        'compiler' => compiler_version, 'erts_build_flags' => build_flags,
        'baseline' => "stock OTP 29.1.2, #{flavour} flavour, native, run with #{Bench::FLAGS.join(' ')}",
        'plan' => plan.to_h.transform_keys(&:to_s), 'guest' => guest, 'stock' => stock.transform_values { |r| r.slice('measurement', 'definition', 'command', 'oracle_build') },
        'stock_footprint' => footprint, 'comparison' => comparison }
    end

    def compiler_version
      command = @runner.run([ENV.fetch('ERX_CLANG'), '--version'], name: 'bench-g3-compiler', deadline: 10)
      File.read(command.fetch('log')).lines.first.to_s.strip
    end

    def build_flags
      text = File.read(File.join(@root, CROSS_FILE))
      FLAG_VARIABLES.to_h { |name| [name, text[/^#{name}="([^"]*)"/, 1]] }
    end

    def write(report, accel)
      parent = OutputDirectory.prepare(root: @root, path: File.join(@root, 'build/bench'))
      path = File.join(Dir.mktmpdir("g3-#{accel}-", parent), 'result.json')
      File.write(path, JSON.pretty_generate(report) + "\n")
      report.merge('report' => path)
    end
  end
end
