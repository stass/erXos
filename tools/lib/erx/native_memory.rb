# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require_relative 'boot_image'
require_relative 'error'
require_relative 'fiasco'
require_relative 'native_root'
require_relative 'qemu'
require_relative 'qemu_cells'
require_relative 'runner'

module Erx
  # The root task's memory end to end on QEMU (docs/design-stopgap.md,
  # "Verification", "Memory"): test/guest/native_memory runs as the root over
  # the backend's five calls through the root service and reports each case on one
  # line. A page with too few rights faults and ends the machine with a crash record
  # before its case's line, and a case that sees wrong contents says FAILED. A page
  # with too many rights shows only in a touch that must fault: see NativeCrash.
  module NativeMemory
    MEMORY_MIB = 512
    SOURCES = [*NativeRoot::RUNTIME, *NativeRoot::VM, *NativeRoot::SERVICE, 'test/guest/native_memory/guest.c'].freeze
    CASES = %w[
      decommit_recommit_reads_zeros no_access_and_back_keeps_contents read_only_raises_to_read_write
      stack_through_no_access refused_protect_changes_nothing write_and_execute_refused refusals
      fixed_reserve_replaces area_top_page_works every_protection_change whole_pool_commits
    ].freeze
    # How a case's line opens, passed or not, so a failure fails at once with its name.
    CASE_LINE = /\Aerx: memory: (?<name>[a-z_]+) (?<result>ok|FAILED)/n
    POOL_LINE = /\Aerx: memory: pool (?<when>before|after) [1-9][0-9]*\r?\n\z/n

    module_function

    # The transcript of one run: the pool's count, each case in order, the count
    # again, and the check that the two agree.
    def checkpoints
      [*Qemu.boot_transcript(memory_mib: MEMORY_MIB),
       pool_point('before'), *CASES.map { |name| case_point(name) }, pool_point('after'),
       case_point('pool_count_steady'), { name: 'memory-done', pattern: /\Aerx: memory: done/n, seconds: 30 }.freeze].freeze
    end

    def case_point(name)
      { name: "memory-#{name}", pattern: /\Aerx: memory: #{name} /n, seconds: 30,
        verify: ->(text) { raise Error, "the memory case reports #{text.inspect}" unless case_passed?(text, name) } }.freeze
    end

    def case_passed?(text, name)
      match = CASE_LINE.match(text)
      !match.nil? && match[:name] == name && match[:result] == 'ok'
    end

    def pool_point(moment)
      { name: "memory-pool-#{moment}", pattern: /\Aerx: memory: pool #{moment} /n, seconds: 30,
        verify: ->(text) { raise Error, "the pool's count reads #{text.inspect}" unless POOL_LINE.match?(text) } }.freeze
    end

    class Run
      # source is the tree the root's C comes from, which a test may seed with a fault.
      def initialize(root:, source: root, runner: Runner.new(owner_root: root, log_dir: File.join(root, 'build/logs')),
                     compiler: ENV.fetch('ERX_CLANG', ''), linker: ENV.fetch('ERX_LLD', ''))
        @root = File.expand_path(root)
        @source = File.expand_path(source)
        @runner = runner
        @compiler = compiler
        @linker = linker
        @build = File.join(@root, 'build/native-memory')
      end

      # Boots the image under each accelerator at each CPU count, with the kernel
      # as last built unless asked to rebuild. Any disagreement raises.
      def call(accels:, cpus: [1, 4], jobs: 4, build: true, placement: QemuCells::HERE)
        fiasco = Fiasco.new(root: @root, runner: @runner, compiler: @compiler)
        fiasco.build(jobs: jobs) if build
        built = image(fiasco)
        placement.each(accels: accels, cpus: cpus) do |accel, count, remote|
          report = Qemu.new(root: @root, runner: @runner).run(accel: accel, cpus: count, remote: remote, image: built.single, memory_mib: MEMORY_MIB,
                                                              checkpoints: NativeMemory.checkpoints, machine_end: true)
          ["#{accel}-#{count}cpu", { serial: report.fetch('serial_log'), seconds: report.fetch('elapsed_seconds') }.freeze]
        end
      end

      private

      def image(fiasco)
        root_task = NativeRoot.new(root: @root, source: @source, runner: @runner, compiler: @compiler, linker: @linker, fiasco: fiasco)
                              .build(name: 'memory-root', sources: SOURCES, directory: File.join(@build, 'root'))
        BootImage.new(root: @root, runner: @runner, compiler: @compiler, linker: @linker)
                 .build(directory: File.join(@build, 'image'), stand_in_root: root_task)
      end
    end
  end
end
