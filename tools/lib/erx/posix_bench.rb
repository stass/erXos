# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'digest'
require_relative 'bench_landing'
require_relative 'bench_measurement'
require_relative 'error'
require_relative 'fiasco'
require_relative 'manifest_edit'
require_relative 'medium_boot'
require_relative 'native_bench'
require_relative 'native_root'
require_relative 'peer_bench'
require_relative 'platform'
require_relative 'production_image'
require_relative 'programs'
require_relative 'qemu'
require_relative 'session_domain'

module Erx
  # erXos's side of the posix benchmark (docs/design-bench.md, "How erXos runs the
  # program"): the programs suite's test image (Programs.test_image) with erx_peer_bench
  # added, the one C file Linux's guest also runs, built for erXos (-DERX_PEER_ERXOS) with
  # PeerBench's flags. Root's session types the program's command at its command shell,
  # the program writes its BENCH lines and its CLOCK line to the session's terminal, and
  # the serial log is read as every guest's is (NativeBench.guest_lines), judged by
  # BenchMeasurement.boot against what a posix run asks (PeerBench.asked).
  module PosixBench
    PROGRAM = 'erx_peer_bench'
    OUTPUT = 'build/posix-bench'
    # Root's session's /tmp cap: the two 16 MiB files of read-seq and copy, and untar's
    # extraction, exceed the development manifest's 2 MiB.
    TMP_MIB = 48
    # The program's define on erXos, beside PeerBench.flags and a seed's.
    ERXOS_FLAG = '-DERX_PEER_ERXOS'

    module_function

    # The image's manifest: source, the development manifest, with root's session's /tmp
    # cap set to TMP_MIB. /tmp is charged to the session's budget as it is used, so the
    # session's memory grows by as much, and so do the system principal's memory, which
    # admits the session, and the machine's root_memory, which holds the principal's. A
    # session's runtime limits stay within its principal's ceiling (dom_limits_within,
    # liberx/system/dom_core.c), the system principal's native limits, whose runtime
    # limits are the system domain's own, so their /tmp cap is raised to TMP_MIB too: a
    # cap, charged only as the system domain's /tmp is used, which nothing here uses.
    def manifest(source)
      tmp = TMP_MIB << 20
      grown = Manifest::Edit.grow(source, { ['limits session', 'memory'] => tmp, ['principal system', 'memory'] => tmp,
                                            %w[machine root_memory] => tmp })
      Manifest::Edit.set(grown, { ['runtime_limits session', 'tmp'] => tmp, ['runtime_limits system', 'tmp'] => tmp })
    end

    # The machine the image boots on: the platform's own, with TMP_MIB more RAM for the
    # root_memory the manifest adds.
    def machine(platform)
      ProductionImage::Machine.development(platform).with(memory_mib: platform.memory_mib + TMP_MIB)
    end

    # The program's flags beyond the tree's: erXos's define, PeerBench's and seeded, a
    # seeded fault's.
    def flags(seeded: []) = [ERXOS_FLAG, *PeerBench.flags, *seeded].freeze

    # The line typed at root's command shell: the program's posix benchmark at the boot's
    # CPU count, which the program places its threads by and never asks the system for.
    def command(cpus) = "#{PROGRAM} posix #{cpus}\r"

    # The boot's checkpoints: the production boot to the system's command shell (points),
    # root's session's command shell, which the command is typed at, and the program's
    # first and last lines, its last due within its own deadline and NativeBench's margin.
    def checkpoints(points, cpus:)
      [*points, SessionDomain.session_shell('root-shell', command(cpus)),
       { name: 'bench-timing', pattern: /\Aerx: bench: timing/n, seconds: 60 },
       { name: 'bench-done', pattern: /\Aerx: bench: done/n,
         seconds: PeerBench::RUN_DEADLINE_SECONDS + NativeBench::DEADLINE_MARGIN_SECONDS }].freeze
    end

    # Builds the image under OUTPUT on platform, with Fiasco as last built. Answers the
    # built image, its machine and manifest, and the program's flags, SHA-256 and compiler
    # (PeerBench.compiler_version, as Linux's record names it).
    def build(root:, runner:, compiler:, linker:, platform:, seeded: [])
      on = machine(platform)
      source = manifest(platform.manifest_source(root))
      built, programs = Programs.test_image(root: root, runner: runner, compiler: compiler, linker: linker, machine: on,
                                            fiasco: Fiasco.new(root: root, runner: runner, compiler: compiler),
                                            build: File.join(root, OUTPUT), programs: { PROGRAM => PeerBench::SOURCE },
                                            manifest_source: source, flags: flags(seeded: seeded))
      { built: built, machine: on, manifest: source, flags: flags(seeded: seeded),
        program_sha256: Digest::SHA256.file(programs.fetch(PROGRAM).fetch(:program)).hexdigest,
        compiler: PeerBench.compiler_version(runner, compiler) }.freeze
    end

    # One boot of the built image (build's answer) at cpus CPUs under accel, its serial
    # log in directory: QEMU's report.
    def boot(root:, runner:, built:, cpus:, accel:, directory:)
      machine = built.fetch(:machine)
      image = built.fetch(:built)
      points = ProductionImage::Run.checkpoints(image, root: root, watchdog: MediumBoot::Run::WATCHDOG, cpus: cpus,
                                                       manifest_source: built.fetch(:manifest),
                                                       memory_mib: machine.memory_mib, test_image: true)
      Qemu.new(root: root, runner: runner)
          .run(platform: machine.platform, accel: accel, cpus: cpus, image: image.single, memory_mib: machine.memory_mib,
               checkpoints: checkpoints(points, cpus: cpus), directory: directory)
    end

    # erXos's posix guest for a comparison session (BenchSystem): one boot of the image,
    # whose program prints a BENCH line for every cell of the posix boot and one CLOCK
    # line. It boots in one CPU and in the landing boot's count, is built with the landing
    # profiles only, as Linux's guest it is set beside, and is built once per session, at
    # its first boot.
    class Guest
      def initialize(root:, runner:, compiler: ENV.fetch('ERX_CLANG', ''), linker: ENV.fetch('ERX_LLD', ''),
                     platform: Platform.development(root))
        @root = File.expand_path(root)
        @runner = runner
        @compiler = compiler
        @linker = linker
        @platform = platform
      end

      def system = 'erxos'
      def boot = 'posix'
      def forms(cpus) = [1, cpus].uniq
      def refusal(profile) = ("erxos's posix image is built with the landing profiles only" unless profile == 'landing')

      def call(benchmark, cells:, cpus:, accel:)
        @built ||= PosixBench.build(root: @root, runner: @runner, compiler: @compiler, linker: @linker, platform: @platform)
        directory = File.join(@root, 'build/qemu', "posix-bench-#{accel}-#{cpus}cpu-#{Process.pid}-#{Random.bytes(8).unpack1('H*')}")
        report = PosixBench.boot(root: @root, runner: @runner, built: @built, cpus: cpus, accel: accel, directory: directory)
        serial = report.fetch('serial_log')
        answer = BenchMeasurement.boot(NativeBench.guest_lines(File.binread(serial)),
                                       PeerBench.asked(benchmark.name, cpus: cpus, clock: 'counter'))
        measured = { serial: serial, image_sha256: report.fetch('image_sha256'), flags: @built.fetch(:flags),
                     compiler: @built.fetch(:compiler), workloads: { PROGRAM => @built.fetch(:program_sha256) },
                     qemu_version: report['qemu_version'], reused_from: report['reused_from'] }
        BenchLanding.booted(measured, answer, memory_mib: @built.fetch(:machine).memory_mib)
      end
    end
  end
end
