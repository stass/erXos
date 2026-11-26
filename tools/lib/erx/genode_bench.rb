# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'digest'
require_relative 'bench_measurement'
require_relative 'bench_record'
require_relative 'bench_system'
require_relative 'error'
require_relative 'genode_build'
require_relative 'json_input'
require_relative 'l4re_bench'
require_relative 'native_bench'
require_relative 'peer_bench'
require_relative 'platform'
require_relative 'posix_bench'
require_relative 'qemu'

module Erx
  # Genode's guest (docs/design-bench.md, "Genode's guest"): base-hw with erx_peer_bench
  # as a component, built out of the tree by Genode's own tools in the oracle's offline
  # container (GenodeBuild), boots as image.elf through the shared QEMU plan as its
  # machine declaration (GenodeBuild::MACHINE) allows: under TCG, entered at the
  # hypervisor's level, on four CPUs, and with its program unpinned. Genode prints the component's log behind its label;
  # the importer drops that label and nothing else, and the lines are judged by
  # BenchMeasurement.boot as Linux's guest's are. Nothing of Genode runs on the host.
  module GenodeBench
    SYSTEM = 'genode-hw'
    # Genode's label of the component's log lines: init's name for its child.
    LABEL = "[init -> #{GenodeBuild::PROGRAM}] ".b.freeze

    # What the container build published into directory for one CPU count: image.elf and
    # its build record, which names the image by its SHA-256, so a stale record never
    # describes a rebuilt image.
    Build = Data.define(:directory) do
      def image = File.join(directory, 'image.elf')
      def record_path = File.join(directory, 'record.json')
      def built? = File.file?(image) && File.file?(record_path)

      def record
        value = JsonInput.parse(File.binread(record_path, (1 << 20) + 1), max_bytes: 1 << 20, label: record_path)
        raise Error, "#{record_path} is not a JSON object of printable ASCII" unless
          BenchRecord.plain_hash?(value) && L4ReBench.printable?(value)
        raise Error, "#{record_path} was not written for #{image}: rebuild Genode's guest" unless
          value['image_sha256'] == Digest::SHA256.file(image).hexdigest

        value
      end
    end

    module_function

    # The build of the image for a boot of cpus CPUs under root.
    def build(root:, cpus:) = Build.new(directory: File.join(root, GenodeBuild.output(cpus)))

    # The program's lines of serial: each line Genode labelled as the component's, the
    # label dropped, that is one of the guest lines; Genode's own lines are not the
    # program's.
    def lines(serial)
      serial.b.split(/\r*\n/n).filter_map { |line| line.delete_prefix(LABEL) if line.start_with?(LABEL) }
            .grep(NativeBench::GUEST_LINE)
    end

    # The checkpoints of a boot: the program's timing line, then its done line, due
    # within the run deadline the image's program was built with, each behind the
    # component's label.
    def checkpoints
      [{ name: 'bench-timing', pattern: /\A#{Regexp.escape(LABEL)}erx: bench: timing/n, seconds: 120 },
       { name: 'bench-done', pattern: /\A#{Regexp.escape(LABEL)}erx: bench: done/n,
         seconds: PeerBench.run_deadline(GenodeBuild.deadline_accelerator) + NativeBench::DEADLINE_MARGIN_SECONDS }]
    end

    # Genode's guest for the posix boot (BenchSystem): one boot of the image built for its
    # machine's CPUs, with no command line and no host link; the program's arguments are in
    # the image's init configuration. It is built with the landing profiles only
    # (PeerBench.flags). Its Booted answers its machine's pinned, so a run of an unpinned
    # machine says so in its record and each of its rows shows it.
    class Guest
      def initialize(root:, runner:, platform: Platform.development(root), qemu: Qemu.new(root: root, runner: runner))
        @root = File.expand_path(root)
        @platform = platform
        @qemu = qemu
      end

      def system = SYSTEM
      def boot = 'posix'
      def accelerators = GenodeBuild::MACHINE.accelerators
      def forms(_cpus) = [GenodeBuild::MACHINE.cpus]

      def refusal(profile)
        "genode's guest is built with the landing profiles only" unless profile == 'landing'
      end

      def call(benchmark, cells:, cpus:, accel:)
        machine = GenodeBuild::MACHINE
        raise Error, "genode's guest boots on #{machine.cpus} CPUs under #{machine.accelerators.join(' or ')}, not #{cpus} under #{accel}" unless
          cpus == machine.cpus && machine.accelerators.include?(accel)

        build = GenodeBench.build(root: @root, cpus: cpus)
        raise Error, "genode's guest has no image: run `tools/erx build genode`" unless build.built?

        subject = build.record
        raise Error, "genode's guest runs only the posix benchmark, not #{benchmark.name}" unless benchmark.name == 'posix'
        # What the tree stages for this run, its arguments and CPU count in the run script,
        # is what the image was built from, or the image is stale.
        staged = GenodeBuild.staged_inputs(@root, arguments: GenodeBuild.arguments, cpus: cpus)
        raise Error, "#{build.record_path} was built from other inputs than the tree stages for " \
                     "#{GenodeBuild.arguments.inspect} on #{cpus} CPUs: rebuild Genode's guest" unless
          subject['staged_sha256'] == GenodeBuild.staged_sha256(staged)

        directory = File.join(@root, 'build/qemu', "genode-bench-#{accel}-#{cpus}cpu-#{Process.pid}-#{Random.bytes(8).unpack1('H*')}")
        memory = PosixBench.machine(@platform).memory_mib
        report = @qemu.run(
          platform: @platform, accel: accel, cpus: cpus, memory_mib: memory, image: build.image,
          hostlink: QemuPlan::NO_HOSTLINK, checkpoints: GenodeBench.checkpoints, machine_end: machine.powers_off, directory: directory,
          virtualization: machine.virtualization
        )
        # The image QEMU booted is the one the record names, even if it was rebuilt meanwhile.
        raise Error, "#{build.image} changed during its boot; its record does not describe the boot" unless
          report.fetch('image_sha256') == subject.fetch('image_sha256')

        serial = report.fetch('serial_log')
        answer = BenchMeasurement.boot(GenodeBench.lines(File.binread(serial)),
                                       PeerBench.asked(benchmark.name, cpus: cpus, clock: 'counter', pinned: machine.pinned))
        BenchSystem::Booted.new(
          clock: answer.fetch(:clock) || {}, cells: answer.fetch(:cells), refused: answer.fetch(:refused),
          environment: { 'memory_mib' => memory, 'machine' => 'virt', 'virtualization' => machine.virtualization,
                         'qemu' => report['qemu_version'] }.compact,
          subject: subject, logs: [{ serial: BenchRecord.boot_log(serial) }], reused_from: report['reused_from'],
          pinned: PeerBench.pins?(benchmark.name, pinned: machine.pinned)
        )
      end
    end
  end
end
