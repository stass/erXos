# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

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
  # and prints the lines erx_xdomain_bench:run/1 answers there; BenchMeasurement.boot is
  # their one judge.
  module XdomainBench
    BOOT = 'xdomain'
    NODE = 'peer@erxos'
    # The bench modules in the order they load: erx_xdomain_bench calls erx_bench_hist.
    MODULES = %w[erx_bench_hist erx_xdomain_bench].freeze
    # How long the shell waits for each module's load and for the cells' lines.
    LOAD_SECONDS = 120
    RUN_SECONDS = 600
    DONE = 'erx: bench: done'

    module_function

    # The system domain suite's echo rows and peer's grant of echo.
    def manifest(source)
      MediumBoot.manifest(source, row: SystemDomain::ECHO_ROW + SystemDomain::PEER_ROW + SystemDomain::ECHO_SERVICES +
                                       SystemDomain::Regrant::PEER_FACET)
    end

    # What the boot asks of its guest: benchmark's xdomain landing cells at their
    # landing profiles, on the counter, which ERTS's monotonic time reads; every cell is
    # stamped on one CPU, so no pair is calibrated.
    def asked(benchmark)
      BenchMeasurement::Asked.new(benchmark: benchmark, cells: benchmark.landing.fetch(BOOT),
                                  profiles: NativeBench.profiles(benchmark), clock: 'counter', pairs: [])
    end

    # The line that runs the cells in peer and prints its answer, a line each, then DONE.
    # The fast profile's sizes and the request's size are asked's, so the guest's
    # conditions are the declared ones.
    def run_line(asked)
      profile = asked.profiles.values.uniq.then { |found| found.one? ? found.first : raise(Error, 'xdomain cells mix profiles') }
      bytes = asked.cells.map { |cell| cell.parameters.fetch('bytes') }.uniq.then do |found|
        found.one? ? found.first : raise(Error, 'xdomain cells ask for different request sizes')
      end
      "[io:put_chars([XbL,$\\n])||XbL<-erpc:call(#{NODE},erx_xdomain_bench,run," \
        "[\#{warmup=>#{profile.warmup},samples=>#{profile.samples},bytes=>#{bytes}}],#{RUN_SECONDS * 1000})]," \
        "io:format(\"#{DONE}~n\").\r"
    end

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

      answers = steps.each_with_index.map do |step, index|
        following = steps[index + 1]&.line
        { name: step.name, pattern: step.answer, seconds: step.seconds, **(following ? { type: following } : {}) }.freeze
      end
      [*points[0...-1], points.last.merge(type: ProductionImage::Run::ERL_LINE).freeze,
       ProductionImage::Run::ERLANG_SHELL.merge(type: steps.first.line).freeze, *answers].freeze
    end

    # One boot of the xdomain bench image: its serial log, seconds, the guest's lines, the
    # image's SHA-256, each bench module's beam's SHA-256 as its workloads, QEMU's version,
    # and the stored log a replayed boot came from (nil for a fresh one).
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
        report = Qemu.new(root: @root, runner: @runner)
                     .run(platform: @machine.platform, accel: accel, cpus: cpus, image: built.single, memory_mib: memory_mib,
                          checkpoints: XdomainBench.checkpoints(points, XdomainBench.exchanges(beams.transform_values(&:bytes), asked)),
                          directory: File.join(@root, 'build/qemu', "xdomain-bench-#{accel}-#{cpus}cpu-#{Process.pid}"))
        serial = File.expand_path(report.fetch('serial_log'), @root)
        { serial: serial, seconds: report.fetch('elapsed_seconds'), lines: NativeBench.guest_lines(File.binread(serial)),
          image_sha256: report.fetch('image_sha256'), workloads: beams.transform_values(&:sha256), compiler: @compiler,
          qemu_version: report['qemu_version'], reused_from: report['reused_from'] }.freeze
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

      # benchmark's xdomain cells booted as boot (a BenchSuite::Boot): the record, the run
      # directory written (nil for a replayed boot) and the refused lines' reasons.
      def call(benchmark, boot:, history:)
        asked = XdomainBench.asked(benchmark)
        @landing.call(asked, boot: boot, memory_mib: @run.memory_mib, history: history) do |accel|
          @run.call(asked, accel: accel, cpus: boot.cpus)
        end
      end
    end
  end
end
