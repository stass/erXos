# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'json'
require_relative 'error'
require_relative 'fiasco'
require_relative 'interactive_boot'
require_relative 'json_input'
require_relative 'production_image'
require_relative 'qemu'

module Erx
  # Gate G3's measurements on the development boot image: boot time to the shell, the
  # footprint at the idle shell, and the four workloads of W1 (docs/design-scheduler.md,
  # E-S1) under QEMU. One boot does all of it, as a person would: the harness types into the
  # Erlang shell, which loads the bench module's beam (the same bytes the stock host runs)
  # and prints one JSON line per measurement. The serial log is the only channel out.
  #
  # Building the transcript and reading the log are pure; the image build and QEMU are the
  # effects at the edge.
  module BenchGuest
    # What one run asks: the workloads' size by accelerator. TCG is slow, so it gets less.
    Plan = Data.define(:accel, :iterations, :samples, :wait_seconds)

    PLANS = {
      'hvf' => Plan.new(accel: 'hvf', iterations: 10_000, samples: 7, wait_seconds: 300),
      'tcg' => Plan.new(accel: 'tcg', iterations: 1_000, samples: 3, wait_seconds: 3_600)
    }.freeze
    # The workloads in the order the run measures them, as erx_otp_bench names them.
    WORKLOADS = %w[pingpong ring spawn switch].freeze
    # A ring hop is a send; one round of the 10,000-process ring is 10,001 of them, so a
    # ring sample sends this many times more than the others' iterations.
    RING_FACTOR = 10
    # The beam travels in lines of this many bytes: the console's line editor reads each.
    CHUNK_BYTES = 256
    LOAD_SECONDS = 120
    BOOT_SECONDS = 600
    # The shell's line of memory in use, the same text the stock host evaluates.
    FOOTPRINT_EXPRESSION = 'io:format("G3FOOT ~s~n",[json:encode(#{memory=>maps:from_list(erlang:memory()),' \
                           'processes=>erlang:system_info(process_count),modules=>length(code:all_loaded()),' \
                           'atoms=>erlang:system_info(atom_count),' \
                           'emu_flavor=>atom_to_binary(erlang:system_info(emu_flavor),utf8),' \
                           'schedulers=>erlang:system_info(schedulers_online),' \
                           'wordsize=>erlang:system_info(wordsize)})]).'
    # The checkpoint names that carry boot time, in the order the guest reaches them.
    BOOT_POINTS = %w[erxos-banner release-slogan release-shell].freeze

    module_function

    # The iterations a workload gets under a plan.
    def iterations_for(workload, plan)
      workload == 'ring' ? plan.iterations * RING_FACTOR : plan.iterations
    end

    # The line the shell evaluates for one workload.
    def workload_line(workload, plan)
      "io:format(\"G3 ~s~n\",[json:encode(erx_otp_bench:run(#{workload},#{iterations_for(workload, plan)}," \
        "#{plan.samples}))]).\r"
    end

    # The beam as numbered shell lines: each binds a piece, and the last loads their join.
    def load_lines(beam)
      pieces = beam.bytes.each_slice(CHUNK_BYTES).map { |slice| "<<#{slice.join(',')}>>" }
      names = pieces.each_index.map { |index| "B#{index}" }
      binds = pieces.zip(names).map { |piece, name| "#{name} = #{piece}, ok.\r" }
      binds + ["{module,erx_otp_bench}=code:load_binary(erx_otp_bench,\"erx_otp_bench.beam\"," \
               "iolist_to_binary([#{names.join(',')}])).\r"]
    end

    # The transcript the harness follows: the boot, then each line typed once the answer to
    # the one before has come. The footprint line is typed at the development warning,
    # before the console starts, and waits in the UART's queue for the shell.
    def checkpoints(beam:, plan:)
      boot = Qemu.boot_transcript(memory_mib: ProductionImage::MEMORY_MIB).map do |point|
        point.fetch(:name) == 'development-warning' ? point.merge(type: "#{FOOTPRINT_EXPRESSION}\r").freeze : point
      end
      lines = load_lines(beam)
      steps = lines.each_cons(2).map { |_, next_line| next_line } + [workload_line(WORKLOADS.first, plan)]
      loads = lines.each_with_index.map do |_, index|
        answer = index == lines.size - 1 ? /\A\{module,erx_otp_bench\}\r*\n\z/n : /\Aok\r*\n\z/n
        { name: "load-#{index}", pattern: answer, seconds: LOAD_SECONDS, type: steps.fetch(index) }.freeze
      end
      [*boot, ProductionImage::Run::SLOGAN,
       { name: 'release-shell', pattern: /\AEshell V/n, seconds: BOOT_SECONDS }.freeze,
       { name: 'footprint', pattern: /\AG3FOOT \{/n, seconds: LOAD_SECONDS }.freeze,
       { name: 'footprint-ok', pattern: /\Aok\r*\n\z/n, seconds: LOAD_SECONDS, type: lines.first }.freeze,
       *loads, *workload_points(plan)].freeze
    end

    # One point per workload; each types the next workload's line and the last types none.
    def workload_points(plan)
      WORKLOADS.each_with_index.map do |workload, index|
        following = WORKLOADS[index + 1]
        point = { name: "workload-#{workload}", pattern: /\AG3 \{/n, seconds: plan.wait_seconds }
        point[:type] = workload_line(following, plan) if following
        point.freeze
      end
    end

    # What the serial log says: the footprint, one measurement per workload and the boot
    # times. A line that is missing is an error, never a default.
    def read_log(text, observed)
      footprint = json_line(text, 'G3FOOT')
      measurements = text.scan(/^G3 (\{.*\})\r?$/).flatten.map do |line|
        JsonInput.parse(line.b, max_bytes: 65_536, label: 'guest measurement')
      end
      raise Error, "the guest printed #{measurements.size} measurements, not #{WORKLOADS.size}" unless
        measurements.size == WORKLOADS.size

      boot = observed.select { |point| BOOT_POINTS.include?(point.fetch('name')) }
                     .to_h { |point| [point.fetch('name'), point.fetch('elapsed_seconds')] }
      raise Error, 'the guest log lacks a boot checkpoint' unless boot.keys.sort == BOOT_POINTS.sort

      { 'boot_seconds' => boot, 'footprint' => footprint, 'measurements' => measurements }
    end

    def json_line(text, tag)
      line = text[/^#{tag} (\{.*\})\r?$/, 1] or raise Error, "the guest log has no #{tag} line"
      JsonInput.parse(line.b, max_bytes: 65_536, label: tag)
    end
    private_class_method :json_line

    # Builds the development image and boots it under the plan's accelerator with the
    # beam loaded through the shell; a given image is booted as it is, not rebuilt. Returns the parsed log with QEMU's own report.
    def run(root:, runner:, plan:, beam:, image: nil, jobs: 4, compiler: ENV.fetch('ERX_CLANG', ''), linker: ENV.fetch('ERX_LLD', ''))
      image ||= InteractiveBoot.build_image(root: root, runner: runner, jobs: jobs, compiler: compiler, linker: linker)
      report = Qemu.new(root: root, runner: runner)
                   .run(accel: plan.accel, cpus: 1, image: image, memory_mib: ProductionImage::MEMORY_MIB,
                        checkpoints: checkpoints(beam: beam, plan: plan),
                        command_line: ProductionImage::Run::COMMAND_LINES[plan.accel])
      read_log(File.binread(report.fetch('serial_log')), report.fetch('checkpoints'))
        .merge('qemu_version' => report.fetch('qemu_version'), 'image_sha256' => report.fetch('image_sha256'),
               'serial_log' => report.fetch('serial_log'), 'qemu_argv' => report.fetch('argv'))
    end
  end
end
