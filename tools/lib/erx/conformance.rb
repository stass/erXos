# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'digest'
require 'json'
require_relative 'bounded_file'
require_relative 'output_directory'
require_relative 'qemu'
require_relative 'runner'

module Erx
  # The target conformance harness (docs/plan.md, M1; docs/design-build.md,
  # "Images and guests"). A roster declares the cases; one guest boots per
  # configuration of the matrix (accelerator by CPU count) and reports each
  # case on its serial line; the harness decides every case's status in
  # every configuration from the roster, the report and how the guest
  # ended, and never reports a result it did not observe.
  #
  # The guest's report, one line each on the serial console:
  #   erx-test: case NAME passed|failed|skipped
  #   erx-test: end COUNT          (COUNT case lines were printed)
  # after which the guest ends the machine; under -no-reboot QEMU then
  # exits by itself, which is the natural exit. A guest the harness kills at
  # its deadline is timed out, whatever it printed.
  module Conformance
    CASE_NAME = /\A[a-z0-9][a-z0-9_.-]{0,63}\z/
    RESULTS = %w[passed failed skipped].freeze
    PREFIX = 'erx-test: '.b
    MAX_PROTOCOL_LINE = 4096
    MAX_CASE_SECONDS = 3600
    MAX_GUEST_SECONDS = 86_400
    SERIAL_BYTES = 64 * 1024 * 1024
    QUOTE_BYTES = 80

    Case = Data.define(:name, :seconds, :pending)
    Config = Data.define(:accel, :cpus) do
      def label = "#{accel}-#{cpus}cpu"
    end
    MATRIX = %w[tcg hvf].product([1, 4]).map { |accel, cpus| Config.new(accel: accel, cpus: cpus) }.freeze

    # The guest's report: the result of each case it named, the count its
    # end line gave (nil without one) and every protocol error.
    Report = Data.define(:results, :ended, :errors)
    EMPTY_REPORT = Report.new(results: {}.freeze, ended: nil, errors: [].freeze)

    module_function

    # Parses a roster: one case per line, `case NAME SECONDS` for a case the
    # guest runs, or `pending NAME SECONDS` for one declared before its
    # call exists, which the matrix shows as pending and nothing runs.
    # Blank lines and lines starting with # are ignored.
    def roster(text, path:)
      cases = text.each_line.with_index(1).filter_map do |line, number|
        fields = line.strip.split
        next if fields.empty? || fields.first.start_with?('#')

        kind, name, seconds = fields
        unless fields.size == 3 && %w[case pending].include?(kind) && CASE_NAME.match?(name) &&
               /\A[1-9][0-9]{0,3}\z/.match?(seconds) && seconds.to_i <= MAX_CASE_SECONDS
          raise Error, "malformed conformance roster line: #{path}:#{number}"
        end

        Case.new(name: name, seconds: seconds.to_i, pending: kind == 'pending')
      end
      names = cases.map(&:name)
      raise Error, "duplicate conformance case in #{path}" unless names.uniq == names

      cases.freeze
    end

    # Parses the protocol lines out of a serial log; every other line is the
    # guest's own output and is ignored. Errors quote guest bytes escaped
    # and truncated.
    def report(bytes)
      results = {}
      ended = nil
      errors = []
      bytes.b.each_line("\n") do |raw|
        line = raw.chomp.delete_suffix("\r")
        next unless line.start_with?(PREFIX)

        if line.bytesize > MAX_PROTOCOL_LINE
          errors << 'overlong protocol line'
          next
        end
        fields = line.byteslice(PREFIX.bytesize..).split(' ', -1)
        if ended
          errors << "protocol line after the end line: #{quote(line)}"
        elsif case_line?(fields) && results.key?(fields[1])
          errors << "case reported twice: #{quote(line)}"
        elsif case_line?(fields)
          results[fields[1]] = fields[2]
        elsif fields.size == 2 && fields[0] == 'end' && /\A(?:0|[1-9][0-9]{0,5})\z/.match?(fields[1])
          ended = fields[1].to_i
        else
          errors << "malformed protocol line: #{quote(line)}"
        end
      end
      errors << "end line counts #{ended} cases, guest reported #{results.size}" if ended && ended != results.size
      Report.new(results: results.freeze, ended: ended, errors: errors.freeze)
    end

    def case_line?(fields)
      fields.size == 3 && fields[0] == 'case' && CASE_NAME.match?(fields[1]) && RESULTS.include?(fields[2])
    end

    def quote(line)
      text = line.byteslice(0, QUOTE_BYTES)
      Terminal.escape(text) + (line.bytesize > QUOTE_BYTES ? '...' : '')
    end

    # Decides one configuration from the roster, the guest's report and how
    # the guest ended: :exited (QEMU exited by itself with status 0),
    # :failed (QEMU exited by itself with another status), :killed (the
    # harness ended it at its deadline) or :unsupported (the host cannot run
    # the configuration). A case is passed, failed or skipped only as the
    # guest reported it; omitted when the guest ended its report without
    # it; unknown when the report never ended; pending as the roster says.
    def verdict(roster, report, ending:)
      raise Error, "unknown guest ending: #{ending}" unless %i[exited failed killed unsupported].include?(ending)

      unreported = if ending == :unsupported then 'unsupported'
                   elsif ending == :exited && report.ended then 'omitted'
                   else 'unknown'
                   end
      cases = roster.to_h do |entry|
        [entry.name, entry.pending ? 'pending' : report.results.fetch(entry.name, unreported)]
      end
      active = roster.reject(&:pending).map(&:name)
      unexpected = report.results.keys - active
      errors = report.errors + unexpected.map { |name| "guest reported a case the roster does not run: #{name}" }
      status = case ending
               when :unsupported then 'unsupported'
               when :killed then 'timed_out'
               when :failed then 'failed'
               else
                 if !errors.empty? || cases.values.any? { |value| %w[failed omitted].include?(value) } then 'failed'
                 # A skip is a case that did not run, so it never passes.
                 elsif report.ended.nil? || cases.value?('skipped') then 'partial'
                 else 'passed'
                 end
               end
      { 'status' => status, 'ending' => ending.to_s, 'cases' => cases, 'errors' => errors }
    end

    # The matrix's overall status: passed only when every configuration
    # passed; failed when any failed; otherwise incomplete.
    def overall(statuses)
      return 'passed' if !statuses.empty? && statuses.all?('passed')
      return 'failed' if statuses.include?('failed')

      'incomplete'
    end

    # Boots the guest once per configuration and records the matrix under
    # build/conformance/. Every guest runs under the Runner's deadline,
    # with -no-reboot and its serial in a bounded log, and its process
    # group is killed when it ends.
    class Run
      def initialize(root:, runner: Runner.new(owner_root: root, log_dir: File.join(root, 'build/logs')),
                     program: 'qemu-system-aarch64', boot_seconds: 60)
        @root = File.expand_path(root)
        @runner = runner
        @program = program
        @boot_seconds = boot_seconds
      end

      def run(image:, roster:, configs: MATRIX, memory_mib: 512)
        image = File.expand_path(image)
        raise Error, "guest image does not exist: #{image}" unless File.file?(image)
        raise Error, 'the conformance roster has no case to run' if roster.all?(&:pending)
        raise Error, 'a conformance configuration is repeated' unless configs.uniq.size == configs.size
        if @boot_seconds + roster.reject(&:pending).sum(&:seconds) > MAX_GUEST_SECONDS
          raise Error, "the roster's deadlines exceed #{MAX_GUEST_SECONDS} seconds per guest"
        end

        directory = OutputDirectory.prepare(root: @root, mode: 0o700,
                                            path: File.join(@root, 'build/conformance',
                                                            "#{Process.pid}-#{Random.bytes(8).unpack1('H*')}"))
        accelerators = available_accelerators
        configurations = configs.map do |config|
          run_config(config, image: image, roster: roster, memory_mib: memory_mib,
                             supported: accelerators.include?(config.accel), directory: directory)
        end
        matrix = { 'image_sha256' => Digest::SHA256.file(image).hexdigest, 'qemu_version' => qemu_version,
                   'status' => Conformance.overall(configurations.map { |entry| entry.fetch('status') }),
                   'configurations' => configurations, 'matrix' => File.join(directory, 'matrix.json') }
        File.write(matrix.fetch('matrix'), JSON.pretty_generate(matrix) + "\n")
        matrix
      end

      private

      def run_config(config, image:, roster:, memory_mib:, supported:, directory:)
        output = OutputDirectory.prepare(root: @root, path: File.join(directory, config.label), mode: 0o700)
        serial = File.join(output, 'serial.log')
        record = { 'configuration' => config.label, 'accel' => config.accel, 'cpus' => config.cpus,
                   'serial_log' => serial }
        if supported
          deadline = @boot_seconds + roster.reject(&:pending).sum(&:seconds)
          argv = QemuPlan.argv(accel: config.accel, image: image, serial: serial, cpus: config.cpus,
                               memory_mib: memory_mib, program: @program)
          ending = boot(argv, name: "conformance-#{config.label}", deadline: deadline)
          bytes = File.file?(serial) ? BoundedFile.read(serial, maximum: SERIAL_BYTES) : ''.b
          record.merge!('argv' => argv, 'deadline_seconds' => deadline)
          record.merge!(Conformance.verdict(roster, Conformance.report(bytes), ending: ending))
        else
          record.merge!(Conformance.verdict(roster, EMPTY_REPORT, ending: :unsupported))
        end
        File.write(File.join(output, 'report.json'), JSON.pretty_generate(record) + "\n")
        record
      end

      def boot(argv, name:, deadline:)
        @runner.run(argv, name: name, deadline: deadline, output_limit: SERIAL_BYTES)
        :exited
      rescue CommandError => error
        error.result.fetch('state') == 'timed_out' ? :killed : :failed
      end

      def available_accelerators
        result = @runner.run([@program, '-accel', 'help'], name: 'qemu-accelerators', deadline: 30)
        QemuPlan.accelerators(BoundedFile.read(result.fetch('log'), maximum: 64 * 1024))
      end

      def qemu_version
        result = @runner.run([@program, '--version'], name: 'qemu-version', deadline: 30)
        Terminal.escape(BoundedFile.read(result.fetch('log'), maximum: 64 * 1024).lines.first.to_s.strip)
      end
    end

    # The matrix as terminal lines: one row per case, one column per
    # configuration, then each configuration's status. Every cell is a
    # roster name or a fixed status word; the CLI's sink escapes it anyway.
    def table(matrix)
      configurations = matrix.fetch('configurations')
      labels = configurations.map { |entry| entry.fetch('configuration') }
      names = configurations.flat_map { |entry| entry.fetch('cases').keys }.uniq
      width = [names.map(&:size).max || 0, 'configuration'.size].max
      row = ->(head, cells) { ([head.ljust(width)] + cells.map { |cell| cell.ljust(11) }).join(' ').rstrip }
      [row.call('case', labels),
       *names.map { |name| row.call(name, configurations.map { |entry| entry.fetch('cases').fetch(name, '-') }) },
       row.call('configuration', configurations.map { |entry| entry.fetch('status') }),
       "conformance: #{matrix.fetch('status')}; #{matrix.fetch('matrix')}"]
    end
  end
end
