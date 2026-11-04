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
  # Threads and timed waits end to end on QEMU (docs/design-stopgap.md,
  # "Verification", "Thread start", "Failed start", "Umtx"): test/guest/native_threads runs as the
  # root and reports each case on one line, then ends the machine through the
  # service, so a run that reaches its last line and exits has served every call.
  module NativeThreads
    MEMORY_MIB = 512
    SOURCES = [*NativeRoot::RUNTIME, *NativeRoot::VM, *NativeRoot::SERVICE, 'test/guest/native_threads/guest.c'].freeze
    CASES = %w[
      tls_and_arg double_start_refused bad_handle_refused wire_refusals umtx_word_differs umtx_past_deadline
      umtx_timeout_not_early umtx_wake_in_order umtx_ping_pong umtx_timeout_races_wake memory_from_threads
      failed_start many_threads indices_run_out
    ].freeze
    # Each case's patience in the guest is 60 seconds: a stall fails its own line.
    CASE_SECONDS = 90

    module_function

    def checkpoints
      [*Qemu.boot_transcript(memory_mib: MEMORY_MIB),
       { name: 'threads-service-up', pattern: /\Aerx: threads: service up/n, seconds: 30 }.freeze,
       *CASES.map { |name| case_point(name) },
       { name: 'threads-done', pattern: /\Aerx: threads: done/n, seconds: 30 }.freeze].freeze
    end

    def case_point(name)
      { name: "threads-#{name}", pattern: /\Aerx: threads: #{name} /n, seconds: CASE_SECONDS,
        verify: ->(text) { raise Error, "the threads case reports #{text.inspect}" unless text.match?(/ ok\r?\n\z/n) } }.freeze
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
        @build = File.join(@root, 'build/native-threads')
      end

      # Boots the image under each accelerator at each CPU count, with the kernel
      # as last built unless asked to rebuild. Any disagreement raises.
      def call(accels:, cpus: [1, 4], jobs: 4, build: true)
        fiasco = Fiasco.new(root: @root, runner: @runner, compiler: @compiler)
        fiasco.build(jobs: jobs) if build
        built = image(fiasco)
        accels.product(cpus).to_h do |accel, count|
          report = Qemu.new(root: @root, runner: @runner).run(accel: accel, cpus: count, image: built.single, memory_mib: MEMORY_MIB,
                                                              checkpoints: NativeThreads.checkpoints, machine_end: true)
          ["#{accel}-#{count}cpu", { serial: report.fetch('serial_log'), seconds: report.fetch('elapsed_seconds') }.freeze]
        end
      end

      private

      def image(fiasco)
        root_task = NativeRoot.new(root: @root, source: @source, runner: @runner, compiler: @compiler, linker: @linker, fiasco: fiasco)
                              .build(name: 'threads-root', sources: SOURCES, directory: File.join(@build, 'root'),
                                     flags: ['-DERX_FIASCO_TEST_HOOKS'])
        BootImage.new(root: @root, runner: @runner, compiler: @compiler, linker: @linker)
                 .build(directory: File.join(@build, 'image'), stand_in_root: root_task)
      end
    end
  end
end
