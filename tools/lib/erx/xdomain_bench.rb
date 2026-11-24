# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'json'
require_relative 'bench'
require_relative 'bench_guest'
require_relative 'bench_landing'
require_relative 'bench_measurement'
require_relative 'error'
require_relative 'fiasco'
require_relative 'medium_boot'
require_relative 'native_bench'
require_relative 'production_image'
require_relative 'qemu'
require_relative 'runner'
require_relative 'system_domain'

module Erx
  # The xdomain bench image (docs/design-bench.md, "5. `xdomain`: one message, one domain
  # to another"): a test image of the system_domain suite's (SystemDomain.test_image) in
  # which erts serves echo through the test-only erx_echo_test and grants it to peer,
  # the client's domain (Regrant::PEER_FACET). At the system's Erlang shell the harness
  # loads the bench modules into peer by erpc, as g3 types its beam (BenchGuest.load_lines),
  # and prints the lines erx_bench_hist:run/1 answers there: one CLOCK line, then each
  # benchmark's cells from its guest module; BenchMeasurement.boot is their one judge.
  module XdomainBench
    BOOT = 'xdomain'
    NODE = 'peer@erxos'
    # The guest module that times each benchmark's cells in this boot.
    GUESTS = { 'xdomain' => 'erx_xdomain_bench', 'wake' => 'erx_wake_bench' }.freeze
    # The bench modules in the order they load: the guest modules call erx_bench_hist.
    MODULES = ['erx_bench_hist', *GUESTS.values].freeze
    # The priorities an erlang-timer cell may ask for, ERTS's process priorities.
    PRIORITIES = %w[low normal high max].freeze
    # How long the shell waits for each module's load and for the cells' lines.
    LOAD_SECONDS = 120
    RUN_SECONDS = 600
    ERPC_SECONDS = 540
    DONE = 'erx: bench: done'

    module_function

    # The system domain suite's echo rows and peer's grant of echo.
    def manifest(source)
      MediumBoot.manifest(source, row: SystemDomain::ECHO_ROW + SystemDomain::PEER_ROW + SystemDomain::ECHO_SERVICES +
                                       SystemDomain::Regrant::PEER_FACET)
    end

    # What the boot asks of its guest: each of benchmarks' landing cells in this boot at
    # their landing profiles, on the counter, which ERTS's monotonic time reads; every
    # cell is stamped on one CPU, so no pair is calibrated.
    def asked(benchmarks)
      BenchMeasurement::Asked.new(benchmarks: benchmarks.map { |benchmark| NativeBench.wanted(benchmark, boot: BOOT) },
                                  clock: 'counter', pairs: [])
    end

    # The line that runs the cells in peer and prints its answer, a line each, then DONE:
    #   [io:put_chars([XbL,$\n])||XbL<-erpc:call(peer@erxos,erx_bench_hist,run,
    #     [[{erx_xdomain_bench,#{warmup=>1000,samples=>10000,bytes=>64}},
    #       {erx_wake_bench,#{samples=>2000,priorities=>[normal]}}]],540000)],
    #   io:format("erx: bench: done~n").
    # Each guest's arguments are its cells' profile sizes and parameters, so the guest's
    # conditions are the declared ones. erpc's deadline ends before the checkpoint's, so
    # a guest that never answers shows as erpc's timeout in the serial log.
    def run_line(asked)
      guests = asked.benchmarks.map do |wanted|
        name = wanted.benchmark.name
        profile = only(wanted.cells.map { |cell| wanted.profiles.fetch(cell.operation) }, "#{name} cells mix profiles")
        "{#{GUESTS.fetch(name)},#{arguments(name, profile, wanted.cells)}}"
      end
      "[io:put_chars([XbL,$\\n])||XbL<-erpc:call(#{NODE},erx_bench_hist,run,[[#{guests.join(',')}]]," \
        "#{ERPC_SECONDS * 1000})],io:format(\"#{DONE}~n\").\r"
    end

    # The guest's lines in a serial log; a boot that timed out may have been cut inside
    # its last line, which a line end has not closed, so that one is dropped.
    def lines(serial, timed_out:)
      closed = timed_out ? serial.b.sub(/[^\n]*\z/n, '') : serial
      NativeBench.guest_lines(closed)
    end

    # The map a benchmark's guest module takes for its cells, which share profile:
    # xdomain's one request size, and wake's erlang-timer priorities, one cell each.
    def arguments(name, profile, cells)
      case name
      in 'xdomain'
        bytes = only(cells.map { |cell| cell.parameters.fetch('bytes') }, 'xdomain cells ask for different request sizes')
        "\#{warmup=>#{profile.warmup},samples=>#{profile.samples},bytes=>#{bytes}}"
      in 'wake'
        raise Error, 'the xdomain boot times only wake\'s erlang-timer' unless cells.all? { |cell| cell.operation == 'erlang-timer' }

        priorities = cells.map { |cell| cell.parameters.fetch('priority') }
        raise Error, "erlang-timer's priority is not one of #{PRIORITIES.join(', ')}" unless (priorities - PRIORITIES).empty?

        "\#{samples=>#{profile.samples},priorities=>[#{priorities.join(',')}]}"
      else raise Error, "the xdomain boot has no guest for #{name}"
      end
    end

    def only(values, mixed) = values.uniq.then { |found| found.one? ? found.first : raise(Error, mixed) }
    private_class_method :arguments, :only

    # Everything typed at the system's Erlang shell after its banner, each with the answer
    # that says it was handled: each module's load lines, from beams, its name to its
    # beam's bytes, then the run line.
    def exchanges(beams, asked)
      loads = MODULES.each_with_index.flat_map do |name, index|
        lines = BenchGuest.load_lines(beams.fetch(name), module_name: name, prefix: "Xb#{index}x", node: NODE)
        lines.each_with_index.map do |line, step|
          answer = step == lines.size - 1 ? BenchGuest::BEAM_DIGEST : BenchGuest::SHELL_OK
          BenchGuest::Exchange.new("load-#{name}-#{step}", line, answer, LOAD_SECONDS)
        end
      end
      [*loads, BenchGuest::Exchange.new('cells', run_line(asked), /\A#{Regexp.escape(DONE)}\r*\n\z/n, RUN_SECONDS)]
    end

    # The production checkpoints to the command shell, which types erl there, the
    # system's Erlang shell, which takes the first exchange's line, then each exchange's
    # answer, which types the next one's.
    def checkpoints(points, steps)
      raise Error, 'the production checkpoints do not end at the shell' unless points.last.fetch(:name) == 'release-shell'

      [*points[0...-1], points.last.merge(type: ProductionImage::Run::ERL_LINE).freeze,
       ProductionImage::Run::ERLANG_SHELL.merge(type: steps.first.line).freeze, *BenchGuest.answers(steps)].freeze
    end

    # One boot of the xdomain bench image: its serial log, seconds, the guest's lines, the
    # image's SHA-256, each bench module's beam's SHA-256 as its workloads, QEMU's version,
    # the stored log a replayed boot came from (nil for a fresh one), and the checkpoint
    # timeout that ended the boot early (nil when it ran to the end). A timed-out boot
    # answers the lines its serial log holds, so the cells it reported keep their verdict.
    class Run
      def initialize(root:, runner: Runner.new(owner_root: root, log_dir: File.join(root, 'build/logs')),
                     compiler: ENV.fetch('ERX_CLANG', ''), linker: ENV.fetch('ERX_LLD', ''),
                     platform: Platform.development(root))
        @root = File.expand_path(root)
        @runner = runner
        @compiler = compiler
        @linker = linker
        @machine = SystemDomain.machine(platform)
        @manifest = XdomainBench.manifest(platform.site_manifest_source(@root))
      end

      def memory_mib = @machine.memory_mib

      def call(asked, accel:, cpus:)
        built = SystemDomain.test_image(root: @root, runner: @runner, compiler: @compiler, linker: @linker,
                                        machine: @machine, fiasco: Fiasco.new(root: @root, runner: @runner, compiler: @compiler),
                                        directory: File.join(@root, 'build/xdomain-bench/image'), manifest: @manifest)
        bench = Bench.new(root: @root, runner: @runner)
        beams = MODULES.to_h { |name| [name, bench.compile_beam(name: name)] }
        points = ProductionImage::Run.checkpoints(built, root: @root, watchdog: MediumBoot::Run::WATCHDOG, cpus: cpus,
                                                         manifest_source: @manifest, memory_mib: memory_mib, test_image: true)
        directory = File.join(@root, 'build/qemu', "xdomain-bench-#{accel}-#{cpus}cpu-#{Process.pid}-#{Random.bytes(8).unpack1('H*')}")
        checkpoints = XdomainBench.checkpoints(points, XdomainBench.exchanges(beams.transform_values(&:bytes), asked))
        report, timed_out = begin
          [Qemu.new(root: @root, runner: @runner)
               .run(platform: @machine.platform, accel: accel, cpus: cpus, image: built.single, memory_mib: memory_mib,
                    checkpoints: checkpoints, directory: directory), nil]
        rescue TranscriptTimeout => e
          # Qemu#run's report of the boot, which it writes however the boot ended.
          [JsonInput.parse(File.binread(File.join(directory, 'report.json'), 1024 * 1024 + 1), max_bytes: 1024 * 1024, label: 'QEMU report'), e.message]
        end
        serial = File.expand_path(report.fetch('serial_log'), @root)
        { serial: serial, seconds: report['elapsed_seconds'], lines: XdomainBench.lines(File.binread(serial), timed_out: timed_out),
          image_sha256: report.fetch('image_sha256'), workloads: beams.transform_values(&:sha256), compiler: @compiler,
          qemu_version: report['qemu_version'], reused_from: report['reused_from'], timed_out: timed_out }.freeze
      end
    end

    # The xdomain boot of the landing matrix (docs/design-bench.md, "The gates"): one boot,
    # recorded (BenchLanding). It has no seeded boot: xdomain's seed is a sensitivity run.
    class Landing
      def initialize(root:, runner: Runner.new(owner_root: root, log_dir: File.join(root, 'build/logs')),
                     run: Run.new(root: root, runner: runner))
        @landing = BenchLanding.new(root: root, runner: runner)
        @run = run
      end

      # benchmarks' xdomain cells booted as boot (a BenchSuite::Boot): the record, the run
      # directory written (nil for a replayed boot), the refused lines' reasons and the
      # timeout that ended the boot early, if one did.
      def call(benchmarks, boot:, history:)
        asked = XdomainBench.asked(benchmarks)
        @landing.call(asked, boot: boot, memory_mib: @run.memory_mib, history: history) do |accel|
          @run.call(asked, accel: accel, cpus: boot.cpus)
        end
      end
    end
  end
end
