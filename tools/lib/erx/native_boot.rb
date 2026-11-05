# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require_relative 'boot_image'
require_relative 'error'
require_relative 'fiasco'
require_relative 'native_root'
require_relative 'qemu'
require_relative 'runner'

module Erx
  # The system's image end to end on QEMU (docs/design-stopgap.md, "Verification",
  # "Native boot"): bootstrap places the kernel, sigma0 and the native root task;
  # the kernel prints erXos's banner; the root task reports the record it took
  # from the handoff page; and the root task ends the machine, so QEMU exits by
  # itself. A root that never powers off fails at the run's deadline.
  module NativeBoot
    MEMORY_MIB = 512

    # What the root's line must report for this archive.
    def self.root_line(built)
      /\Aerx: root task: build #{built.build_id} index #{built.index_hash} entries [0-9]+\r?\n\z/n
    end

    # The transcript of one boot of this archive, each checkpoint in its order.
    def self.checkpoints(built)
      line = root_line(built)
      root = { name: 'root-task', pattern: /\Aerx: root task/n, seconds: 30,
               verify: ->(text) { raise Error, "the root task reports #{text.inspect}, not this image" unless line.match?(text) } }.freeze
      [*Qemu.boot_transcript(memory_mib: MEMORY_MIB), root].freeze
    end

    class Run
      def initialize(root:, runner: Runner.new(owner_root: root, log_dir: File.join(root, 'build/logs')),
                     compiler: ENV.fetch('ERX_CLANG', ''), linker: ENV.fetch('ERX_LLD', ''))
        @root = File.expand_path(root)
        @runner = runner
        @compiler = compiler
        @linker = linker
        @build = File.join(@root, 'build/native-boot')
      end

      # Rebuilds the kernel, so make decides what is stale, unless the caller has
      # just built it, then boots the image under each accelerator at each CPU
      # count. Returns each run's serial log and boot time; any disagreement raises.
      def call(accels:, cpus: [1, 4], jobs: 4, build: true)
        Fiasco.new(root: @root, runner: @runner, compiler: @compiler).build(jobs: jobs) if build
        built = image
        points = NativeBoot.checkpoints(built)
        accels.product(cpus).to_h do |accel, count|
          report = Qemu.new(root: @root, runner: @runner).run(accel: accel, cpus: count, image: built.single, memory_mib: MEMORY_MIB,
                                                              checkpoints: points, machine_end: true)
          ["#{accel}-#{count}cpu", { serial: report.fetch('serial_log'), seconds: report.fetch('elapsed_seconds') }.freeze]
        end
      end

      private

      def image
        root_task = NativeRoot.new(root: @root, runner: @runner, compiler: @compiler, linker: @linker)
                              .build_no_program(directory: File.join(@build, 'root'))
        BootImage.new(root: @root, runner: @runner, compiler: @compiler, linker: @linker)
                 .build(directory: File.join(@build, 'image'), stand_in_root: root_task)
      end
    end
  end
end
