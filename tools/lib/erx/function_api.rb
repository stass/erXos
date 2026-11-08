# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require_relative 'boot_image'
require_relative 'error'
require_relative 'hosted_sources'
require_relative 'fiasco'
require_relative 'native_root'
require_relative 'qemu'
require_relative 'runner'

module Erx
  # The function-API set that both backends pass (docs/design-stopgap.md, "The call
  # table"): test/guest/function_api compiled hosted, which test/host/hosted_function_api_test.rb
  # runs under each sanitizer, and for native Fiasco's root task, which Run boots here.
  module FunctionApi
    MEMORY_MIB = 512
    PREFIX = 'erx: function-api: '
    CASES = %w[
      decommit_recommit_reads_zeros released_pages_read_zeros no_access_and_back_keeps_contents
      read_only_raises_to_read_write stack_through_no_access refused_protect_changes_nothing
      write_and_execute_refused refusals fixed_reserve_replaces every_protection_change many_pages_between_write_and_execute whole_pool_commits
      pool_count_steady tls_and_arg utcb_is_each_threads double_start_refused bad_handle_refused unsupported_refused group_info_and_configure object_info
      umtx_word_differs umtx_past_deadline umtx_timeout_not_early umtx_wake_counts umtx_ping_pong
      umtx_timeout_races_wake memory_from_threads affinity_refused join_loop detached_loop park_refusals park_alone
      park_trigger_in_window park_ping park_timeout_races_wake many_threads machine_end_refused
      entropy_read entropy_add entropy_refusals mem_device_refusals
    ].freeze
    # The IRQ row: what both backends pass, and what holds only hosted (irq_cases.c).
    IRQ_CASES = %w[irq_refusals irq_ack_unbound irq_wakes_parked irq_objects_run_out].freeze
    HOSTED_IRQ_CASES = %w[irq_refusals irq_ack_unbound irq_line_refused irq_ready_once irq_wakes_parked irq_objects_run_out].freeze
    # The devices' row: what takes a device natively, then the handle cases, whose calls only
    # native has; and hosted, that there is no device.
    DEVICE_CASES = %w[physical_reads_registers physical_refusals contiguous_runs contiguous_device_writes
                      generations stale_handle dup_and_close].freeze
    HOSTED_DEVICE_CASES = %w[mem_device_refused].freeze
    LAST_CASE = 'indices_run_out'
    GUEST = HostedSources::GUEST
    HOSTED_SOURCES = HostedSources::ALL
    NATIVE_SOURCES = [*NativeRoot::RUNTIME, *NativeRoot::VM, *NativeRoot::SERVICE, 'liberx/backend/core/refused.c',
                      'liberx/backend/fiasco/api_names.c', 'build/gen/liberx/generated/abi_reader.c', "#{GUEST}/cases.c", "#{GUEST}/guest.c", "#{GUEST}/irq_cases.c", "#{GUEST}/device_cases.c",
                      "#{GUEST}/handle_cases.c"].freeze
    # Each case's patience in the guest is 60 seconds: a stall fails its own line.
    CASE_SECONDS = 90
    # The join loop's deletions each wait for a grace period, which across CPUs under TCG takes far longer.
    LONG_CASES = { 'join_loop' => 300 }.freeze

    module_function

    def hosted_lines
      [*(CASES + HOSTED_IRQ_CASES + HOSTED_DEVICE_CASES + [LAST_CASE]).map { |name| "#{PREFIX}#{name} ok" }, "#{PREFIX}done"]
    end

    def checkpoints
      [*Qemu.boot_transcript(memory_mib: MEMORY_MIB),
       { name: 'entropy-quality', pattern: /\Aerx: entropy: quality: low, from the counter alone/n, seconds: 30 }.freeze,
       { name: 'function-api-up', pattern: /\A#{Regexp.escape(PREFIX)}service up/n, seconds: 30 }.freeze,
       *[*CASES, *IRQ_CASES, *DEVICE_CASES, LAST_CASE].map do |name|
         { name: "function-api-#{name}", pattern: /\A#{Regexp.escape(PREFIX)}#{name} ok/n,
           seconds: LONG_CASES.fetch(name, CASE_SECONDS) }.freeze
       end,
       { name: 'function-api-done', pattern: /\A#{Regexp.escape(PREFIX)}done/n, seconds: 30 }.freeze].freeze
    end

    class Run
      def initialize(root:, source: root, runner: Runner.new(owner_root: root, log_dir: File.join(root, 'build/logs')),
                     compiler: ENV.fetch('ERX_CLANG', ''), linker: ENV.fetch('ERX_LLD', ''))
        @root = File.expand_path(root)
        @source = File.expand_path(source)
        @runner = runner
        @compiler = compiler
        @linker = linker
        @build = File.join(@root, 'build/function-api')
      end

      # Boots the image under each accelerator at each CPU count, with the kernel
      # as last built unless asked to rebuild. Any disagreement raises.
      def call(accels:, cpus: [1, 4], jobs: 4, build: true)
        fiasco = Fiasco.new(root: @root, runner: @runner, compiler: @compiler)
        fiasco.build(jobs: jobs) if build
        built = image(fiasco)
        accels.product(cpus).to_h do |accel, count|
          report = Qemu.new(root: @root, runner: @runner).run(accel: accel, cpus: count, image: built.single, memory_mib: MEMORY_MIB,
                                                              checkpoints: FunctionApi.checkpoints, machine_end: true)
          ["#{accel}-#{count}cpu", { serial: report.fetch('serial_log'), seconds: report.fetch('elapsed_seconds') }.freeze]
        end
      end

      private

      def image(fiasco)
        root_task = NativeRoot.new(root: @root, source: @source, runner: @runner, compiler: @compiler, linker: @linker, fiasco: fiasco)
                              .build(name: 'function-api-root', sources: NATIVE_SOURCES, directory: File.join(@build, 'root'),
                                     flags: ['-DERX_FIASCO_TEST_HOOKS'])
        BootImage.new(root: @root, runner: @runner, compiler: @compiler, linker: @linker)
                 .build(directory: File.join(@build, 'image'), stand_in_root: root_task)
      end
    end
  end
end
