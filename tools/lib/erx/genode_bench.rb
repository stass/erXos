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
  # Genode's guest under HVF (docs/design-bench.md, "Genode's guest"): base-hw with
  # erx_peer_bench as a component, built out of the tree by Genode's own tools in the
  # oracle's offline container (GenodeBuild) for one CPU count, boots as image.elf
  # through the shared QEMU plan. Genode prints the component's log behind its label;
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

    # The checkpoints of a boot: the program's timing line, then its done line, each
    # behind the component's label.
    def checkpoints
      [{ name: 'bench-timing', pattern: /\A#{Regexp.escape(LABEL)}erx: bench: timing/n, seconds: 120 },
       { name: 'bench-done', pattern: /\A#{Regexp.escape(LABEL)}erx: bench: done/n,
         seconds: PeerBench::RUN_DEADLINE_SECONDS + NativeBench::DEADLINE_MARGIN_SECONDS }]
    end

    # Genode's guest for the posix boot (BenchSystem): one boot of the image built for the
    # session's CPU count, with no command line and no host link; the program's
    # arguments are in the image's init configuration. It is built with the landing
    # profiles only (PeerBench.flags).
    class Guest
      def initialize(root:, runner:, platform: Platform.development(root))
        @root = File.expand_path(root)
        @runner = runner
        @platform = platform
      end

      def system = SYSTEM
      def boot = 'posix'
      def forms(cpus) = [1, cpus].uniq

      def refusal(profile)
        "genode's guest is built with the landing profiles only" unless profile == 'landing'
      end

      def call(benchmark, cells:, cpus:, accel:)
        build = GenodeBench.build(root: @root, cpus: cpus)
        raise Error, "genode's guest has no image for #{cpus} CPUs: run `tools/erx build genode --cpus #{cpus}`" unless
          build.built?

        subject = build.record
        raise Error, "#{build.record_path} runs #{subject['arguments'].inspect}, not #{benchmark.name} on #{cpus} CPUs" unless
          subject['arguments'] == PeerBench.arguments(benchmark.name, cpus: cpus) && subject['cpus'] == cpus

        directory = File.join(@root, 'build/qemu', "genode-bench-#{accel}-#{cpus}cpu-#{Process.pid}-#{Random.bytes(8).unpack1('H*')}")
        memory = PosixBench.machine(@platform).memory_mib
        report = Qemu.new(root: @root, runner: @runner).run(
          platform: @platform, accel: accel, cpus: cpus, memory_mib: memory, image: build.image,
          hostlink: QemuPlan::NO_HOSTLINK, checkpoints: GenodeBench.checkpoints, machine_end: true, directory: directory
        )
        # The image QEMU booted is the one the record names, even if it was rebuilt meanwhile.
        raise Error, "#{build.image} changed during its boot; its record does not describe the boot" unless
          report.fetch('image_sha256') == subject.fetch('image_sha256')

        serial = report.fetch('serial_log')
        answer = BenchMeasurement.boot(GenodeBench.lines(File.binread(serial)),
                                       PeerBench.asked(benchmark.name, cpus: cpus, clock: 'counter'))
        BenchSystem::Booted.new(
          clock: answer.fetch(:clock) || {}, cells: answer.fetch(:cells), refused: answer.fetch(:refused),
          environment: { 'memory_mib' => memory, 'machine' => 'virt', 'qemu' => report['qemu_version'] }.compact,
          subject: subject, logs: [{ serial: BenchRecord.boot_log(serial) }], reused_from: report['reused_from']
        )
      end
    end
  end
end
