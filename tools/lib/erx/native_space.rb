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
  # Memory objects mapped between the root and two tasks on native Fiasco, and fault
  # gates that take the tasks' records: the root
  # test/guest/native_space/guest.c and the tasks' program.c beside it. Each case says
  # one line, and the transcript must show each passed, in order.
  module NativeSpace
    MEMORY_MIB = 512
    PROGRAM_PATH = 'boot/native-space'
    ROOT_SOURCES = [*NativeRoot::RUNTIME, *NativeRoot::VM, *NativeRoot::SERVICE, *NativeRoot::LAUNCH,
                    'liberx/backend/core/refused.c', 'test/guest/native_space/guest.c'].freeze
    PROGRAM_SOURCES = [*NativeRoot::TASK, 'test/guest/native_space/program.c'].freeze
    CASES = %w[program_found writer_released between_tasks bounds revoke gate_refusals gate_queue].freeze
    CASE_LINE = /\Aerx: space: (?<name>[a-z_]+) (?<result>ok|FAILED)/n

    module_function

    def checkpoints
      [*Qemu.boot_transcript(memory_mib: MEMORY_MIB),
       *CASES.map { |name| case_point(name, seconds: name == 'program_found' ? 180 : 60) },
       { name: 'space-done', pattern: /\Aerx: space: done/n, seconds: 30 }.freeze].freeze
    end

    def case_point(name, seconds:)
      { name: "space-#{name}", pattern: /\Aerx: space: #{name} /n, seconds: seconds,
        verify: ->(text) { raise Error, "the space case reports #{text.inspect}" unless case_passed?(text, name) } }.freeze
    end

    def case_passed?(text, name)
      match = CASE_LINE.match(text)
      !match.nil? && match[:name] == name && match[:result] == 'ok'
    end

    # Builds the image and boots it at each accelerator and CPU count.
    class Run
      def initialize(root:, runner: Runner.new(owner_root: root, log_dir: File.join(root, 'build/logs')),
                     compiler: ENV.fetch('ERX_CLANG', ''), linker: ENV.fetch('ERX_LLD', ''))
        @root = File.expand_path(root)
        @runner = runner
        @compiler = compiler
        @linker = linker
        @build = File.join(@root, 'build/native-space')
      end

      def call(accels:, cpus: [1, 4], jobs: 4, build: true)
        fiasco = Fiasco.new(root: @root, runner: @runner, compiler: @compiler)
        fiasco.build(jobs: jobs) if build
        built = image(fiasco)
        accels.product(cpus).to_h do |accel, count|
          report = Qemu.new(root: @root, runner: @runner).run(accel: accel, cpus: count, image: built.single, memory_mib: MEMORY_MIB,
                                                              checkpoints: NativeSpace.checkpoints, machine_end: true)
          ["#{accel}-#{count}cpu", { serial: File.expand_path(report.fetch('serial_log'), @root),
                                     seconds: report.fetch('elapsed_seconds') }.freeze]
        end
      end

      private

      def image(fiasco)
        native = NativeRoot.new(root: @root, source: @root, runner: @runner, compiler: @compiler, linker: @linker, fiasco: fiasco)
        program = native.build_task(name: 'native-space', sources: PROGRAM_SOURCES, directory: File.join(@build, 'program'), flags: [])
        root_task = native.build(name: 'space-root', sources: ROOT_SOURCES, directory: File.join(@build, 'root'), flags: [])
        BootImage.new(root: @root, runner: @runner, compiler: @compiler, linker: @linker)
                 .build(directory: File.join(@build, 'image'), stand_in_root: root_task, programs: { PROGRAM_PATH => program })
      end
    end
  end
end
