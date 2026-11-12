# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'json'
require 'time'
require 'tmpdir'
require_relative 'bench'
require_relative 'bench_g3'
require_relative 'bench_guest'
require_relative 'error'
require_relative 'interactive_boot'
require_relative 'json_input'
require_relative 'production_image'
require_relative 'qemu'

module Erx
  # erx_bytes's network primitives timed on erXos under QEMU HVF (bench/erx_bytes_bench.erl):
  # each input through the function the stack calls, interleaved round by round. One boot
  # does it: the harness types the beam into the Erlang shell, as G3 does (BenchGuest), and
  # the guest prints one JSON line. The report is build/bench/bytes-hvf-*/result.json. The
  # beam is the same for any image, so --image times another build's erx_bytes against it.
  class BenchBytes
    Plan = Data.define(:iterations, :samples, :wait_seconds)
    PLAN = Plan.new(iterations: 100_000, samples: 9, wait_seconds: 900)
    MODULE = 'erx_bytes_bench'
    MEASUREMENT = /\ABYTES (\{.*\})\r*\n?\z/n
    INPUTS = %w[siphash20 siphash8 csum_iolist csum_binary csum_pseudo csum_ip_header].freeze

    def initialize(root:, runner: nil, platform: Platform.development(root))
      @root = File.realpath(root)
      @platform = platform
      @runner = runner || Runner.new(owner_root: @root, log_dir: File.join(@root, 'build/logs'))
      @bench = Bench.new(root: @root, runner: @runner)
    end

    # Boots the image (built here unless one is given) and writes the report.
    def run(image: nil, jobs: 4)
      build = BenchG3.new(root: @root, runner: @runner).build_record(image)
      beam = @bench.compile_beam(flavour: 'jit', name: MODULE)
      image ||= InteractiveBoot.build_image(root: @root, runner: @runner, jobs: jobs, platform: @platform)
      before = @bench.load_average
      directory = File.join(@root, 'build/qemu', "bytes-hvf-#{Process.pid}-#{Random.bytes(4).unpack1('H*')}")
      failure = boot(image: image, beam: beam, directory: directory)
      after = @bench.load_average
      serial = File.join(directory, 'serial.log')
      text = File.file?(serial) ? File.binread(serial) : ''.b
      qemu = read_json(File.join(directory, 'report.json'))
      write(self.class.report(host: @bench.host_description, now: Time.now.utc, build: build, beam: beam,
                              qemu: qemu, serial: serial, failure: failure, plan: PLAN,
                              measurement: self.class.measurement(text),
                              load: { 'before' => before, 'after' => after }))
    end

    # The guest's JSON line in the serial log, or nil when it never printed one.
    def self.measurement(text)
      line = text.each_line.find { |candidate| MEASUREMENT.match?(candidate) }
      line && JsonInput.parse(MEASUREMENT.match(line)[1], max_bytes: 65_536, label: 'bytes measurement')
    end

    # The report: each workload's samples and median, and each input's median less the
    # loop's, so the call's own cost is what is compared. Pure.
    def self.report(host:, now:, build:, beam:, qemu:, serial:, failure:, plan:, measurement:, load:)
      workloads = measurement ? measurement.fetch('workloads') : {}
      medians = workloads.filter_map do |name, entry|
        [name, BenchG3.median(entry.fetch('ns_per_call'))] if entry.fetch('status') == 'measured'
      end.to_h
      { 'benchmark' => 'bytes', 'host' => host, 'accelerator' => 'hvf', 'measured_at' => now.iso8601,
        'qemu_version' => qemu['qemu_version'], 'image_sha256' => qemu['image_sha256'],
        'qemu_state' => qemu.fetch('state', 'failed'), 'error' => failure&.message, 'serial_log' => serial,
        'build' => build, 'beam_sha256' => beam.sha256, 'host_load' => load,
        'plan' => { 'iterations' => plan.iterations, 'samples' => plan.samples },
        'guest' => measurement&.reject { |key, _| key == 'workloads' },
        'workloads' => workloads, 'median_ns_per_call' => medians,
        'net_of_loop' => net_of_loop(medians), 'complete' => !measurement.nil? }
    end

    # Each input's median less the loop's; nil for an input the guest did not measure.
    def self.net_of_loop(medians)
      loop_ns = medians['loop']
      return {} unless loop_ns

      INPUTS.to_h { |input| [input, medians[input]&.then { |ns| (ns - loop_ns).round(1) }] }
    end

    private

    def boot(image:, beam:, directory:)
      loads = BenchGuest.load_lines(beam.bytes, module_name: MODULE)
      steps = loads.each_with_index.map do |line, index|
        answer = index == loads.size - 1 ? BenchGuest::BEAM_DIGEST : BenchGuest::SHELL_OK
        BenchGuest::Exchange.new("load-#{index}", line, answer, BenchGuest::LOAD_SECONDS)
      end
      line = "io:format(\"BYTES ~s~n\",[json:encode(#{MODULE}:run(#{PLAN.iterations},#{PLAN.samples}))]).\r"
      steps << BenchGuest::Exchange.new('measure', line, MEASUREMENT, PLAN.wait_seconds)
      Qemu.new(root: @root, runner: @runner)
          .run(platform: @platform, accel: 'hvf', cpus: 1, image: image, memory_mib: @platform.memory_mib,
               checkpoints: BenchGuest.transcript(steps, platform: @platform), directory: directory)
      nil
    rescue Error => error
      error
    end

    def read_json(path)
      return {} unless File.file?(path)

      JsonInput.parse(File.binread(path, 1024 * 1024 + 1), max_bytes: 1024 * 1024, label: 'QEMU report')
    end

    def write(report)
      parent = OutputDirectory.prepare(root: @root, path: File.join(@root, 'build/bench'))
      path = File.join(Dir.mktmpdir('bytes-hvf-', parent), 'result.json')
      File.write(path, JSON.pretty_generate(report) + "\n")
      report.merge('report' => path)
    end
  end
end
