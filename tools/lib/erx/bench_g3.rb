# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'json'
require 'time'
require_relative 'bench'
require_relative 'bench_guest'

module Erx
  # Gate G3's measurements (docs/plan.md, M3): W1 of E-S1, the footprint at shell start
  # and boot time to the shell, on erXos under QEMU and on stock OTP on this host, in one
  # report. The guest runs under the one accelerator asked for, and the stock runs use the
  # iterations and samples that accelerator's guest ran, so every pair of numbers shares a
  # workload. TCG and HVF numbers are two reports, never compared with each other.
  #
  # The report says, for each workload, whether it was measured, timed out, is missing or
  # was rejected by a check, and the run is complete only when every one was measured.
  class BenchG3
    # The ERTS build's flags, as the target's cross-compile file states them.
    CROSS_FILE = 'otp/xcomp/erl-xcomp-aarch64-unknown-erxos.conf'
    FLAG_VARIABLES = %w[ERX_TARGET_FLAGS CFLAGS CXXFLAGS LDFLAGS].freeze
    # What the report says of the build of an image it was handed.
    IMAGE_SUPPLIED = 'unknown: image supplied'

    def initialize(root:, runner: nil)
      @root = File.realpath(root)
      @runner = runner || Runner.new(owner_root: @root, log_dir: File.join(@root, 'build/logs'))
      @bench = Bench.new(root: @root, runner: @runner)
    end

    # Runs the guest, then the stock side, and writes build/bench/g3-<accel>-*/result.json,
    # complete or not. The report's 'complete' says whether every measurement was made.
    def run(accel:, flavour: 'emu', jobs: 4, image: nil)
      plan = BenchGuest::PLANS.fetch(accel) { raise Error, "no G3 plan for accelerator #{accel}" }
      build = build_record(image)
      beam = @bench.compile_beam(flavour: flavour)
      guest, guest_load = with_load do
        BenchGuest.run(root: @root, runner: @runner, plan: plan, beam: beam.bytes,
                       flavour: flavour, image: image, jobs: jobs)
      end
      (stock, stock_footprint), stock_load = with_load { stock_side(plan, flavour, beam) }
      write(self.class.report(host: @bench.host_description, now: Time.now.utc, plan: plan,
                              flavour: flavour, guest: guest, stock: stock,
                              stock_footprint: stock_footprint, build: build, beam: beam,
                              load: { 'guest' => guest_load, 'stock' => stock_load }), accel)
    end

    # The report, from the two sides' results. Pure: it only arranges what it is given.
    def self.report(host:, now:, plan:, flavour:, guest:, stock:, stock_footprint:, build:, beam:, load:)
      comparison = BenchGuest::WORKLOADS.to_h do |workload|
        [workload, compare_entry(guest.fetch('workloads').fetch(workload), stock.fetch(workload))]
      end
      measured = comparison.values.all? { |entry| entry['status'] == 'compared' }
      { 'kind' => 'g3', 'date' => now.iso8601, 'host' => host, 'host_load' => load,
        'accelerator' => plan.accel, 'qemu' => guest['qemu_version'] || 'unknown',
        'compiler' => build.fetch('compiler'), 'erts_build_flags' => build.fetch('flags'),
        'baseline' => "stock OTP 29.1.2, #{flavour} flavour, native, run with #{Bench::FLAGS.join(' ')}",
        'plan' => plan.to_h.transform_keys(&:to_s),
        'beam' => { 'sha256' => beam.sha256, 'guest_md5' => guest.fetch('beam') },
        'guest' => guest, 'stock' => stock.transform_values { |run| stock_summary(run) },
        'stock_footprint' => stock_footprint, 'comparison' => comparison,
        'complete' => measured && guest.fetch('state') == 'passed' &&
                      guest.fetch('footprint').fetch('status') == 'measured' }
    end

    # What the report keeps of a stock run.
    def self.stock_summary(run) = run.slice('measurement', 'definition', 'command', 'oracle_build')

    # One workload's guest entry set against the stock measurement of the same workload. The
    # two ran the same operations of the same beam, or the pair is refused.
    def self.compare_entry(guest_entry, stock_run)
      return { 'status' => guest_entry.fetch('status'), 'reason' => guest_entry.fetch('reason') } unless
        guest_entry.fetch('status') == 'measured'

      guest = guest_entry.fetch('measurement')
      stock = stock_run.fetch('measurement')
      same_run = %w[operations beam_md5].all? { |field| guest.fetch(field) == stock.fetch(field) }
      return { 'status' => 'rejected', 'reason' => 'guest and stock ran other operations or another beam' } unless same_run

      compare(guest, stock).merge('status' => 'compared')
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

    # Stock OTP's four workloads at the guest's sizes, with the one compiled beam, and its
    # footprint. A host failure raises: only the guest is allowed to end a run half-way.
    def stock_side(plan, flavour, beam)
      runs = BenchGuest::WORKLOADS.to_h do |workload|
        report = @bench.run("otp-#{workload}", flavour: flavour, samples: plan.samples, beam: beam,
                                               iterations: BenchGuest.iterations_for(workload, plan))
        [workload, report]
      end
      [runs, @bench.footprint(flavour: flavour)]
    end

    # The block's result and the host's load average before and after it.
    def with_load
      before = @bench.load_average
      result = yield
      [result, { 'before' => before, 'after' => @bench.load_average }]
    end

    # The compiler and flags of the image under test, gathered before it boots. An image that
    # was handed in was built elsewhere, so this tree says nothing about it.
    def build_record(image)
      return { 'compiler' => IMAGE_SUPPLIED, 'flags' => IMAGE_SUPPLIED } if image

      { 'compiler' => compiler_version, 'flags' => build_flags }
    end

    def compiler_version
      clang = ENV.fetch('ERX_CLANG', '')
      raise Error, 'ERX_CLANG names no compiler; G3 needs it to build and describe the image' if clang.empty?

      command = @runner.run([clang, '--version'], name: 'bench-g3-compiler', deadline: 10)
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
