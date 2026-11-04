# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'fileutils'
require_relative 'bounded_file'
require_relative 'error'
require_relative 'fiasco'
require_relative 'output_directory'
require_relative 'qemu'
require_relative 'runner'

module Erx
  # The first call across the kernel interface on the stopgap, end to end: the
  # probe of test/guest/debug_log_probe makes good and malformed erx_debug_log
  # calls on the hosted backend and as the root task on QEMU, and each run's
  # transcript must equal the expected one, so the backends agree case by case.
  module DebugLogProbe
    GUEST = 'test/guest/debug_log_probe'
    EXPECTED = 'test/fixtures/debug_log_probe.expected'
    MEMORY_MIB = 512
    SERIAL_BYTES = 16 * 1024 * 1024
    # A rendered record: `#SEQ SECONDS.MICROSECONDS LEVEL space N[ dropped K]: TEXT`.
    RECORD = /\A#(?<seq>[0-9]+) (?<seconds>[0-9]+)\.(?<micros>[0-9]{6}) (?<level>[a-z]+) space (?<space>[0-9]+)(?: dropped (?<dropped>[0-9]+))?: (?<text>.*)\z/n
    Record = Data.define(:seq, :time, :level, :space, :dropped, :text)
    # The probe's flood: PROBE_FLOOD in probe.c lines of this text.
    FLOOD_LINES = 64
    FLOOD_TEXT = '\x01'.b
    AFTER_FLOOD = 'after the flood'
    HOSTED_SOURCES = %w[
      kernel/core/admit.c kernel/core/debug_log.c kernel/core/dispatch.c kernel/core/log.c
      kernel/generated/abi_decode.c kernel/generated/abi_run.c
      liberx/backend/hosted/generated/calls.c liberx/backend/hosted/log.c
      test/guest/debug_log_probe/hosted.c test/guest/debug_log_probe/probe.c
    ].freeze
    HOSTED_FLAGS = %w[-std=c17 -D_DARWIN_C_SOURCE -D_GNU_SOURCE -Wall -Wextra -Werror -pedantic -O1 -g -pthread
                      -I include -I kernel/generated -I kernel/core -I . -I test/guest/debug_log_probe].freeze
    GUEST_SOURCES = %w[
      liberx/backend/fiasco/arch/aarch64/generated/trap.c liberx/backend/fiasco/arch/aarch64/utcb.c
      liberx/backend/fiasco/generated/calls.c
      test/guest/debug_log_probe/guest.c test/guest/debug_log_probe/probe.c test/guest/debug_log_probe/start.S
    ].freeze
    GUEST_FLAGS = %w[--target=aarch64-none-elf -std=c17 -Wall -Wextra -Werror -pedantic -O2 -ffreestanding
                     -fno-stack-protector -mgeneral-regs-only -mno-outline-atomics
                     -I include -I . -I liberx/backend/fiasco/generated -I test/guest/debug_log_probe].freeze

    module_function

    # The records of a serial log or a hosted run's standard error. Anything
    # that is not a record, such as the boot's own output, is ignored.
    def records(bytes)
      bytes.b.each_line("\n").filter_map do |raw|
        match = RECORD.match(raw.chomp.delete_suffix("\r"))
        next unless match

        Record.new(seq: match[:seq].to_i, time: [match[:seconds].to_i, match[:micros].to_i], level: match[:level],
                   space: match[:space].to_i, dropped: match[:dropped]&.to_i, text: match[:text])
      end.freeze
    end

    # What both backends must agree on: each record's text and whether it
    # reports dropped lines. A space's number, a clock and a sequence number
    # differ between runs. How many flood lines the limit lets through depends
    # on the width of the space's number, so adjacent flood lines count once;
    # accounting_errors counts them exactly.
    def transcript(bytes)
      lines = records(bytes).map { |record| "#{record.dropped ? 'dropped: ' : ''}#{record.text}" }
      lines.chunk_while { |first, second| first == second && flood?(first) }.map(&:first).freeze
    end

    def flood?(text) = text.start_with?(FLOOD_TEXT)

    # What one run must hold true by itself, whatever the other backend did:
    # sequence numbers count up by one, the clock never runs back, every line
    # is one non-zero space's at debug level, and every flood line either
    # appeared or was counted as dropped.
    def accounting_errors(bytes)
      records = records(bytes)
      flood = records.count { |record| flood?(record.text) }
      dropped = records.find { |record| record.text == AFTER_FLOOD }&.dropped
      [("sequence numbers do not count up by one" unless records.each_cons(2).all? { |a, b| b.seq == a.seq + 1 }),
       ('the clock ran back' unless records.each_cons(2).all? { |a, b| (a.time <=> b.time) <= 0 }),
       ('a line is not at debug level' unless records.all? { |record| record.level == 'debug' }),
       ('lines name other than one non-zero space' unless records.map(&:space).uniq.size == 1 && records.first&.space&.positive?),
       ("the flood shows #{flood} lines and counts #{dropped.inspect} dropped" unless dropped && flood + dropped == FLOOD_LINES)].compact.freeze
    end

    # The first difference between two transcripts, for the operator.
    def difference(expected, actual)
      index = (0...[expected.size, actual.size].max).find { |position| expected[position] != actual[position] }
      return nil unless index

      "line #{index + 1}: expected #{expected[index].inspect}, got #{actual[index].inspect}"
    end

    class Run
      def initialize(root:, source: root, runner: Runner.new(owner_root: root, log_dir: File.join(root, 'build/logs')),
                     compiler: ENV.fetch('ERX_CLANG', ''), linker: ENV.fetch('ERX_LLD', ''),
                     host_compiler: ENV.fetch('CC', 'cc'))
        @root = File.expand_path(root)
        @source = File.expand_path(source)
        @runner = runner
        @compiler = compiler
        @linker = linker
        @host_compiler = host_compiler
        @build = File.join(@root, 'build/debug-log-probe')
      end

      # Rebuilds the kernel from the tree, so make decides what is stale and a
      # run can never judge an old kernel, then runs the probe under each
      # accelerator at each CPU count. Returns each run's serial log and image
      # hash; any disagreement raises.
      def call(accels:, cpus: [1, 4], jobs: 4)
        expected = DebugLogProbe.transcript(BoundedFile.read(File.join(@source, EXPECTED), maximum: SERIAL_BYTES))
        raise Error, 'the expected debug-log transcript is empty' if expected.empty?

        judge('hosted', expected, hosted_output)
        Fiasco.new(root: @root, runner: @runner, compiler: @compiler).build(jobs: jobs)
        image = guest_image
        accels.product(cpus).to_h do |accel, count|
          report = Qemu.new(root: @root, runner: @runner).run(accel: accel, cpus: count, image: image,
                                                              memory_mib: MEMORY_MIB, checkpoints: checkpoints)
          serial = report.fetch('serial_log')
          judge("#{accel}-#{count}cpu", expected, BoundedFile.read(serial, maximum: SERIAL_BYTES))
          ["#{accel}-#{count}cpu", { serial: serial, image_sha256: report.fetch('image_sha256') }.freeze]
        end
      end

      # The hosted program's output, the same records a guest's serial log holds.
      def hosted_output(sanitizers: [])
        OutputDirectory.prepare(root: @root, path: @build)
        program = File.join(@build, 'hosted')
        @runner.run([@host_compiler, *HOSTED_FLAGS, *sanitizers, *HOSTED_SOURCES, '-o', program],
                    name: 'debug-log-hosted-compile', deadline: 120, chdir: @source)
        result = @runner.run([program], name: 'debug-log-hosted', deadline: 60)
        BoundedFile.read(result.fetch('log'), maximum: SERIAL_BYTES)
      end

      private

      def checkpoints
        [*Qemu.boot_transcript(memory_mib: MEMORY_MIB),
         { name: 'probe-end', pattern: / space [0-9]+: probe end\r?\n/n, seconds: 120 }.freeze].freeze
      end

      def judge(name, expected, bytes)
        difference = DebugLogProbe.difference(expected, DebugLogProbe.transcript(bytes))
        raise Error, "debug-log probe: #{name} disagrees, #{difference}" if difference

        errors = DebugLogProbe.accounting_errors(bytes)
        raise Error, "debug-log probe: #{name}: #{errors.join('; ')}" unless errors.empty?
      end

      def guest_image
        raise Error, 'set ERX_CLANG to the installed LLVM clang' if @compiler.empty?
        raise Error, 'set ERX_LLD to the installed ld.lld' if @linker.empty?

        directory = File.join(@build, 'guest')
        FileUtils.mkdir_p(directory)
        objects = GUEST_SOURCES.map do |source|
          object = File.join(directory, "#{File.basename(source).tr('.', '_')}.o")
          @runner.run([@compiler, *GUEST_FLAGS, '-c', source, '-o', object],
                      name: "debug-log-guest-#{File.basename(source).tr('.', '-').downcase}", deadline: 60, chdir: @source)
          object
        end
        guest = File.join(directory, 'debug_log_probe')
        @runner.run([@linker, '-T', File.join(GUEST, 'link.ld'), '-o', guest, *objects],
                    name: 'debug-log-guest-link', deadline: 60, chdir: @source)
        Fiasco.new(root: @root, runner: @runner, compiler: @compiler)
              .debug_log_image(guest: guest, modules: File.join(@source, GUEST, 'modules.list'),
                               directory: File.join(@build, 'image'))
      end
    end
  end
end
