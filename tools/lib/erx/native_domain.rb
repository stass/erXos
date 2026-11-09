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
  # The domain library's apply phase on native Fiasco: the root
  # test/guest/native_domain/guest.c links liberx/system and creates domains whose
  # tasks run program.c beside it, and takes their ends at its fault gate. Each case
  # says one line, and the transcript must show each passed, in order.
  module NativeDomain
    MEMORY_MIB = 512
    PROGRAM_PATH = 'boot/native-domain'
    # The domains' release: one file, which program.c reads through its slice.
    RELEASE_PATH = 'domains/native/release'
    RELEASE_SOURCE = 'test/guest/native_domain/release.txt'
    SYSTEM = %w[liberx/system/dom_core.c liberx/system/dom_life.c liberx/system/dom_apply.c
                liberx/backend/core/boot_info.c liberx/erx_lane.c].freeze
    ROOT_SOURCES = [*NativeRoot::RUNTIME, *NativeRoot::VM, *NativeRoot::SERVICE, *NativeRoot::LAUNCH,
                    'liberx/backend/core/refused.c', *SYSTEM, 'test/guest/native_domain/string.c',
                    'test/guest/native_domain/guest.c'].freeze
    ROOT_FLAGS = %w[-DERX_DOM_TEST_HOOKS].freeze
    PROGRAM_SOURCES = [*NativeRoot::TASK, 'test/guest/native_domain/program.c'].freeze
    CASES = %w[library warm halt fault stop lanes link_warm link link_undo link_end undo].freeze
    CASE_LINE = /\Aerx: domain: (?<name>[a-z_]+) (?<result>ok|FAILED)/n

    module_function

    def checkpoints
      [*Qemu.boot_transcript(memory_mib: MEMORY_MIB),
       *CASES.map { |name| case_point(name, seconds: name == 'library' ? 180 : 60) },
       { name: 'domain-done', pattern: /\Aerx: domain: done/n, seconds: 30 }.freeze].freeze
    end

    def case_point(name, seconds:)
      { name: "domain-#{name}", pattern: /\Aerx: domain: #{name} /n, seconds: seconds,
        verify: ->(text) { raise Error, "the domain case reports #{text.inspect}" unless case_passed?(text, name) } }.freeze
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
        @build = File.join(@root, 'build/native-domain')
      end

      def call(accels:, cpus: [1, 4], jobs: 4, build: true)
        fiasco = Fiasco.new(root: @root, runner: @runner, compiler: @compiler)
        fiasco.build(jobs: jobs) if build
        built = image(fiasco)
        accels.product(cpus).to_h do |accel, count|
          report = Qemu.new(root: @root, runner: @runner).run(accel: accel, cpus: count, image: built.single, memory_mib: MEMORY_MIB,
                                                              checkpoints: NativeDomain.checkpoints, machine_end: true)
          ["#{accel}-#{count}cpu", { serial: File.expand_path(report.fetch('serial_log'), @root),
                                     seconds: report.fetch('elapsed_seconds') }.freeze]
        end
      end

      private

      def image(fiasco)
        native = NativeRoot.new(root: @root, source: @root, runner: @runner, compiler: @compiler, linker: @linker, fiasco: fiasco)
        program = native.build_task(name: 'native-domain', sources: PROGRAM_SOURCES, directory: File.join(@build, 'program'), flags: [])
        root_task = native.build(name: 'domain-root', sources: ROOT_SOURCES, directory: File.join(@build, 'root'), flags: ROOT_FLAGS)
        programs = { PROGRAM_PATH => program, RELEASE_PATH => File.join(@root, RELEASE_SOURCE) }
        BootImage.new(root: @root, runner: @runner, compiler: @compiler, linker: @linker)
                 .build(directory: File.join(@build, 'image'), stand_in_root: root_task, programs: programs)
      end
    end
  end
end
