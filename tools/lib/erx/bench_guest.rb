# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'json'
require_relative 'error'
require_relative 'bench_guest_log'
require_relative 'fiasco'
require_relative 'interactive_boot'
require_relative 'json_input'
require_relative 'production_image'
require_relative 'qemu'

module Erx
  # Gate G3's measurements on the development boot image: boot time to the command shell,
  # the footprint at the Erlang shell's start, and the four workloads of W1 (docs/design-scheduler.md,
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
    # The ring is asked for this many times the iterations as sends. The module rounds that
    # down to whole rounds of 10,001 sends (at least one) and reports the sends it made as
    # the measurement's operations, so a ring's iterations are not its sends.
    RING_FACTOR = 10
    # The beam travels in lines of this many bytes: the console's line editor reads each.
    CHUNK_BYTES = 256
    LOAD_SECONDS = 120
    BOOT_SECONDS = 600
    # The shell's line of memory in use, the same text the stock host evaluates. The time
    # unit is what the guest's clock counts in and is recorded in the report. The run bounds
    # the guest's timed total from above by the host's clock; a slow guest clock is not caught.
    FOOTPRINT_EXPRESSION =
      'io:format("G3FOOT ~s~n",[json:encode(#{memory=>maps:from_list(erlang:memory()),' \
      'processes=>erlang:system_info(process_count),modules=>length(code:all_loaded()),' \
      'atoms=>erlang:system_info(atom_count),' \
      'emu_flavor=>atom_to_binary(erlang:system_info(emu_flavor),utf8),' \
      'schedulers=>erlang:system_info(schedulers_online),' \
      'native_time_unit_hz=>erlang:convert_time_unit(1,second,native),' \
      'wordsize=>erlang:system_info(wordsize)})]).'
    # The shell's answers: the value of a line that printed nothing worth reading is ok;
    # the load line prints its beam's digest; a workload prints its measurement.
    # The boot checkpoint at which the first line is typed.
    FIRST_LINE_AT = 'development-warning'
    SHELL_OK = /\Aok\r*\n\z/n
    BEAM_DIGEST = /\AG3BEAM [0-9a-f]{32}\r*\n\z/n
    MEASUREMENT = /\AG3 \{/n

    # One line typed into the shell and the answer that says it was handled. A step with no
    # line is a second answer to the line before it (the footprint prints, then evaluates
    # to ok).
    Exchange = Data.define(:name, :line, :answer, :seconds)

    module_function

    # The iterations a workload gets under a plan.
    def iterations_for(workload, plan)
      workload == 'ring' ? plan.iterations * RING_FACTOR : plan.iterations
    end

    # The iterations each workload is asked for, in the order the run does them.
    def asked(plan) = WORKLOADS.to_h { |workload| [workload, iterations_for(workload, plan)] }

    # The line the shell evaluates for one workload.
    def workload_line(workload, plan)
      "io:format(\"G3 ~s~n\",[json:encode(erx_otp_bench:run(#{workload}," \
        "#{iterations_for(workload, plan)},#{plan.samples}))]).\r"
    end

    # The beam as numbered shell lines: each binds a piece, and the last loads their join and
    # prints the digest of the module that loaded.
    def load_lines(beam, module_name: 'erx_otp_bench')
      pieces = beam.bytes.each_slice(CHUNK_BYTES).map { |slice| "<<#{slice.join(',')}>>" }
      names = pieces.each_index.map { |index| "B#{index}" }
      binds = pieces.zip(names).map { |piece, name| "#{name} = #{piece}, ok.\r" }
      binds + ["{module,#{module_name}}=code:load_binary(#{module_name},\"#{module_name}.beam\"," \
               "iolist_to_binary([#{names.join(',')}])),io:format(\"G3BEAM ~s~n\"," \
               "[binary:encode_hex(#{module_name}:module_info(md5),lowercase)]).\r"]
    end

    # Everything typed at the Erlang shell, in order. The first line is typed at the Erlang
    # shell's banner; each later line is typed when the answer to the one before it has
    # come. The erl line that starts that shell is typed at the development warning, before
    # the console starts, and waits in the UART's queue for the command shell.
    def exchanges(beam:, plan:)
      loads = load_lines(beam)
      [Exchange.new('footprint', "#{FOOTPRINT_EXPRESSION}\r", /\AG3FOOT \{/n, LOAD_SECONDS),
       Exchange.new('footprint-ok', nil, SHELL_OK, LOAD_SECONDS),
       *loads.each_with_index.map do |line, index|
         answer = index == loads.size - 1 ? BEAM_DIGEST : SHELL_OK
         Exchange.new("load-#{index}", line, answer, LOAD_SECONDS)
       end,
       *WORKLOADS.map do |workload|
         Exchange.new("workload-#{workload}", workload_line(workload, plan), MEASUREMENT, plan.wait_seconds)
       end]
    end

    # The transcript the harness follows: the boot to the command shell, the Erlang shell
    # started there, then a checkpoint for each exchange's answer that types the next
    # exchange's line.
    def checkpoints(beam:, plan:, platform:) = transcript(exchanges(beam: beam, plan: plan), platform: platform)

    # The transcript for any exchanges typed at the Erlang shell, the first at its banner,
    # on platform's board.
    def transcript(steps, platform:)
      boot = Qemu.boot_transcript(memory_mib: platform.memory_mib).map do |point|
        point.fetch(:name) == FIRST_LINE_AT ? point.merge(type: ProductionImage::Run::ERL_LINE).freeze : point
      end
      raise Error, "the boot transcript has no #{FIRST_LINE_AT} point to type at" unless
        boot.any? { |point| point.key?(:type) }
      answers = steps.each_with_index.map do |step, index|
        point = { name: step.name, pattern: step.answer, seconds: step.seconds }
        following = steps[index + 1]&.line
        point[:type] = following if following
        point.freeze
      end
      [*boot, ProductionImage::Run::SLOGAN,
       ProductionImage::Run::RELEASE_SHELL.merge(seconds: BOOT_SECONDS).freeze,
       ProductionImage::Run::ERLANG_SHELL.merge(seconds: LOAD_SECONDS, type: steps.first.line).freeze,
       *answers].freeze
    end

    # Boots the development image (built here unless one is given) under the plan's
    # accelerator with the beam loaded through the shell, and reads what the guest printed.
    # A timeout or QEMU failure does not discard it: the result says how the run ended and
    # each workload says whether it was measured.
    def run(root:, runner:, plan:, beam:, flavour:, image: nil, jobs: 4,
            compiler: ENV.fetch('ERX_CLANG', ''), linker: ENV.fetch('ERX_LLD', ''), platform: Platform.development(root))
      image ||= InteractiveBoot.build_image(root: root, runner: runner, jobs: jobs, platform: platform,
                                            compiler: compiler, linker: linker)
      points = checkpoints(beam: beam, plan: plan, platform: platform)
      directory = File.join(root, 'build/qemu', "g3-#{plan.accel}-#{Process.pid}-#{Random.bytes(4).unpack1('H*')}")
      failure = boot(root: root, runner: runner, plan: plan, image: image, points: points, directory: directory,
                     platform: platform)
      settle(directory: directory, failure: failure, points: points, plan: plan, flavour: flavour)
    end

    # QEMU's run, returning the error that ended it (or nil) instead of raising it.
    def boot(root:, runner:, plan:, image:, points:, directory:, platform:)
      Qemu.new(root: root, runner: runner)
          .run(platform: platform, accel: plan.accel, cpus: 1, image: image, memory_mib: platform.memory_mib,
               checkpoints: points, command_line: ProductionImage::Run::COMMAND_LINES[plan.accel],
               directory: directory)
      nil
    rescue Error => error
      error
    end
    private_class_method :boot

    # The result of one run from the report QEMU's run leaves in its directory (it writes
    # one however the run ends) and the serial log. Without a report nothing was observed.
    def settle(directory:, failure:, points:, plan:, flavour:)
      report = read_report(File.join(directory, 'report.json'))
      observed = report.fetch('checkpoints', [])
      serial = File.join(directory, 'serial.log')
      text = File.file?(serial) ? File.binread(serial) : ''.b
      state = report.fetch('state', 'failed')
      log = BenchGuestLog.read_log(text, observed, expected: asked(plan), samples: plan.samples,
                                                   flavour: flavour, timed_out: state == 'timed_out',
                                                   awaiting: points[observed.size]&.fetch(:name))
      { 'state' => state, 'error' => failure&.message, 'qemu_version' => report['qemu_version'],
        'image_sha256' => report['image_sha256'], 'serial_log' => serial,
        'qemu_argv' => report['argv'], 'checkpoints' => observed }.merge(log)
    end
    private_class_method :settle

    def read_report(path)
      return {} unless File.file?(path)

      JsonInput.parse(File.binread(path, 1024 * 1024 + 1), max_bytes: 1024 * 1024, label: 'QEMU report')
    end
    private_class_method :read_report
  end
end
