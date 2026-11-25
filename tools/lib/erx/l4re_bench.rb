# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'digest'
require_relative 'bench_system'
require_relative 'error'
require_relative 'ipcbench'
require_relative 'json_input'
require_relative 'native_bench'
require_relative 'qemu'

module Erx
  # L4Re's guest under HVF (docs/design-bench.md, "L4Re's guest"): upstream Fiasco and
  # L4Re's ipcbench, built out of the tree by L4Re's own make in the oracle's offline
  # container, boot as bootstrap.elf through the shared QEMU plan, and their lines come
  # back through L4Re's importer (Ipcbench). Nothing of L4Re runs on the host: the host
  # boots the exported ELF in QEMU and reads the serial log.
  module L4ReBench
    # The guest's RAM: the same as erXos's native bench image, so the two boots differ
    # only in what they run.
    MEMORY_MIB = NativeBench::MEMORY_MIB
    # The configuration script's last line; the guest does not halt, so its boot ends
    # here, as at a deadline.
    DONE = { name: 'l4re-benchmarks-done', pattern: /Benchmarks done\./n, seconds: 300 }.freeze

    # What the container build exported into directory: bootstrap.elf and the build
    # record written beside it, a JSON object of the pins, hashes, resolved
    # configuration, toolchain and boot arguments, which every run's subject keeps. The
    # record names the ELF it was written for by its SHA-256, so a stale record never
    # describes a rebuilt ELF.
    Build = Data.define(:directory) do
      def bootstrap = File.join(directory, 'bootstrap.elf')
      def record_path = File.join(directory, 'build-record.json')
      def built? = File.file?(bootstrap) && File.file?(record_path)

      # The build record of the ELF as it is now, refused unless it is a JSON object whose
      # keys and strings are printable ASCII and whose bootstrap_sha256 is the ELF's.
      def record
        value = JsonInput.parse(File.binread(record_path, (1 << 20) + 1), max_bytes: 1 << 20, label: record_path)
        raise Error, "#{record_path} is not a JSON object of printable ASCII" unless
          BenchRecord.plain_hash?(value) && L4ReBench.printable?(value)
        unless value['bootstrap_sha256'] == Digest::SHA256.file(bootstrap).hexdigest
          raise Error, "#{record_path} was not written for #{bootstrap}: rebuild L4Re's guest"
        end

        value
      end
    end

    # Whether every key and string of a parsed JSON value is printable ASCII.
    def self.printable?(value)
      case value
      when Hash then value.all? { |key, item| printable?(key) && printable?(item) }
      when Array then value.all? { |item| printable?(item) }
      when String then value.b.match?(/\A[ -~]*\z/n)
      else true
      end
    end

    # L4Re's guest for the native boot (BenchSystem): one boot of bootstrap.elf on one
    # CPU, the only form in which ipcbench's unpinned threads have a known placement,
    # with no command line and no host link. Its cells are means in cycles, so its
    # record has no clock group.
    class Guest
      def initialize(build:, qemu:, platform:)
        @build = build
        @qemu = qemu
        @platform = platform
      end

      def system = 'l4re'
      def boot = 'native'
      def forms(_cpus) = [1]

      def refusal(_profile)
        return nil if @build.built?

        "l4re's guest needs #{@build.bootstrap} and its build record, which L4Re's container build exports"
      end

      def call(benchmark, cells:, cpus:, accel:)
        raise Error, "l4re boots on one CPU, not #{cpus}" unless cpus == 1

        subject = @build.record
        report = @qemu.run(platform: @platform, accel: accel, cpus: 1, image: @build.bootstrap, memory_mib: MEMORY_MIB,
                           checkpoints: [DONE], hostlink: QemuPlan::NO_HOSTLINK, directory: directory(accel))
        # The ELF QEMU booted is the one the record names, even if it was rebuilt meanwhile.
        unless report.fetch('image_sha256') == subject.fetch('bootstrap_sha256')
          raise Error, "#{@build.bootstrap} changed during its boot; its record does not describe the boot"
        end
        serial = report.fetch('serial_log')
        answer = Ipcbench.import(File.binread(serial).split(/\r?\n/n), benchmark: benchmark.name, cells: cells)
        BenchSystem::Booted.new(
          clock: nil, cells: answer.fetch(:cells), refused: answer.fetch(:refused),
          environment: { 'memory_mib' => MEMORY_MIB, 'machine' => 'virt', 'qemu' => report['qemu_version'] }.compact,
          subject: subject,
          logs: [{ serial: serial }], reused_from: report['reused_from']
        )
      end

      private

      def directory(accel)
        File.join(File.dirname(@build.directory), 'qemu',
                  "l4re-bench-#{accel}-#{Process.pid}-#{Random.bytes(8).unpack1('H*')}")
      end
    end
  end
end
