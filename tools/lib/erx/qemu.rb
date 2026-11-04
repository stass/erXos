# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'digest'
require 'fileutils'
require 'set'
require 'json'
require_relative 'bootstrap_memory'
require_relative 'runner'

module Erx
  class TranscriptTimeout < Error; end

  module QemuPlan
    module_function

    def argv(accel:, image:, serial:, cpus: 1, memory_mib: 512,
             program: 'qemu-system-aarch64', initrd: nil)
      raise Error, 'accelerator must be tcg or hvf' unless %w[tcg hvf].include?(accel)
      raise Error, 'CPU count must be between 1 and 8' unless cpus.is_a?(Integer) && cpus.between?(1, 8)
      unless memory_mib.is_a?(Integer) && memory_mib.between?(128, 4096)
        raise Error, 'guest memory must be between 128 and 4096 MiB'
      end
      [image, serial, program].each do |value|
        raise Error, 'invalid QEMU path' unless value.is_a?(String) && !value.empty? && !value.include?("\0")
      end

      machine = 'virt-11.1,gic-version=3'
      machine += ',msi=gicv2m' if accel == 'tcg'
      [program, '-machine', machine, '-accel', accel,
       '-cpu', accel == 'hvf' ? 'host' : 'cortex-a76',
       '-smp', cpus.to_s, '-m', memory_mib.to_s,
       '-display', 'none', '-monitor', 'none', '-nic', 'none',
       '-no-reboot', '-serial', "file:#{serial}", '-kernel', image,
       *(initrd ? ['-initrd', initrd] : [])].freeze
    end

    # The accelerators `qemu-system-aarch64 -accel help` lists: one name per
    # line after its heading. A configuration whose accelerator is absent
    # is unsupported on this host, which the conformance matrix shows as
    # such rather than as a failure or a pass.
    def accelerators(text)
      text.b.lines.map(&:strip).grep(/\A[a-z][a-z0-9_-]{0,31}\z/).to_set.freeze
    end
  end

  # The matcher consumes complete serial lines exactly once. It retains a
  # bounded unfinished line so serial splits cannot lose a checkpoint. A
  # checkpoint may also name a verifier, called with the matching line, which
  # raises Erx::Error when that line's content must fail the boot.
  class Transcript
    MAX_LINE_BYTES = 65_536
    REQUIRED_KEYS = %i[name pattern seconds].freeze
    OPTIONAL_KEYS = %i[verify].freeze
    attr_reader :observed

    def initialize(checkpoints:)
      unless checkpoints.is_a?(Array) && !checkpoints.empty? &&
             checkpoints.all? { |point| point.is_a?(Hash) && checkpoint_keys?(point) }
        raise Error, 'invalid transcript checkpoint plan'
      end
      names = checkpoints.map { |point| point.fetch(:name) }
      raise Error, 'duplicate transcript checkpoint name' unless names.uniq == names
      raise Error, 'invalid transcript checkpoint' unless checkpoints.all? { |point| valid_checkpoint?(point) }

      @checkpoints = checkpoints.map(&:dup).each(&:freeze).freeze
      @observed = []
      @pending = ''.b
      @offset = 0
      @checkpoint_started = 0.0
    end

    def consume(path, elapsed:)
      check_deadline(elapsed: elapsed)
      if File.file?(path)
        File.open(path, 'rb') do |input|
          input.seek(@offset)
          chunk = input.read(64 * 1024)
          if chunk
            @offset += chunk.bytesize
            @pending << chunk
            consume_lines(elapsed: elapsed)
          end
        end
      end
      done?
    end

    def drain(path, elapsed:)
      while File.file?(path) && @offset < File.size(path) && !done?
        consume(path, elapsed: elapsed)
      end
      check_deadline(elapsed: elapsed)
      done?
    end

    def done?
      @observed.size == @checkpoints.size
    end

    private

    def checkpoint_keys?(point)
      (REQUIRED_KEYS - point.keys).empty? && (point.keys - REQUIRED_KEYS - OPTIONAL_KEYS).empty?
    end

    def valid_checkpoint?(point)
      point.fetch(:name).is_a?(String) && !point.fetch(:name).empty? &&
        point.fetch(:pattern).is_a?(Regexp) &&
        point.fetch(:seconds).is_a?(Integer) && point.fetch(:seconds).positive? &&
        point.fetch(:verify, -> {}).respond_to?(:call)
    end

    def check_deadline(elapsed:)
      return if done?
      point = @checkpoints.fetch(@observed.size)
      if elapsed - @checkpoint_started >= point.fetch(:seconds)
        raise TranscriptTimeout, "QEMU checkpoint timed out: #{point.fetch(:name)}"
      end
    end

    def consume_lines(elapsed:)
      while (newline = @pending.index("\n"))
        raise Error, 'serial line exceeds transcript bound' if newline > MAX_LINE_BYTES
        line = @pending.slice!(0, newline + 1)
        next if done?
        point = @checkpoints.fetch(@observed.size)
        next unless point.fetch(:pattern).match?(line)

        point[:verify]&.call(line)
        @observed << { 'name' => point.fetch(:name), 'elapsed_seconds' => elapsed }.freeze
        @checkpoint_started = elapsed
      end
      raise Error, 'serial line exceeds transcript bound' if @pending.bytesize > MAX_LINE_BYTES
    end
  end

  class Qemu
    BANNER = [
      { name: 'erxos-art', pattern: %r{/_/\\_\\ \\___/ \|___/\r?\n}n, seconds: 30 }.freeze,
      { name: 'erxos-banner', pattern: /erXos\r?\n/n, seconds: 30 }.freeze,
      { name: 'development-warning', pattern: /development build: trusted code only\r?\n/n,
        seconds: 30 }.freeze
    ].freeze

    # The default guest transcript: bootstrap's memory summary, checked
    # against the RAM QEMU is given, then the kernel banner lines.
    def self.boot_transcript(memory_mib:)
      raise Error, 'guest memory must be a whole number of MiB' unless memory_mib.is_a?(Integer)

      [BootstrapMemory.checkpoint(ram_bytes: memory_mib << 20), *BANNER].freeze
    end

    def initialize(root:, runner: Runner.new(owner_root: root, log_dir: File.join(root, 'build/logs')),
                   program: 'qemu-system-aarch64', initrd: nil)
      @root = File.expand_path(root)
      @runner = runner
      @program = program
    end

    # With machine_end the guest must end the machine itself: the run lasts
    # until QEMU exits, and a guest still running at the deadline fails it, as
    # does one that exits before its transcript is complete. Otherwise the
    # harness ends the guest at the last checkpoint.
    def run(accel:, image:, cpus: 1, memory_mib: 512, checkpoints: nil, initrd: nil, machine_end: false)
      checkpoints ||= self.class.boot_transcript(memory_mib: memory_mib)
      image = File.expand_path(image)
      raise Error, "guest image does not exist: #{image}" unless File.file?(image)
      matcher = Transcript.new(checkpoints: checkpoints)
      deadline = checkpoints.sum { |point| point.fetch(:seconds) } + 5
      directory = File.join(@root, 'build/qemu', "#{accel}-#{Process.pid}-#{Random.bytes(8).unpack1('H*')}")
      directory = OutputDirectory.prepare(root: @root, path: directory, mode: 0o700)
      serial = File.join(directory, 'serial.log')
      argv = QemuPlan.argv(accel: accel, image: image, serial: serial,
                           cpus: cpus, memory_mib: memory_mib, program: @program, initrd: initrd)
      report = { 'state' => 'running', 'image_sha256' => Digest::SHA256.file(image).hexdigest,
                 'argv' => argv, 'checkpoints' => matcher.observed, 'serial_log' => serial }
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      begin
        version = @runner.run([@program, '--version'], name: 'qemu-version', deadline: 10)
        report['qemu_version'] = File.binread(version.fetch('log')).lines.first.to_s.strip
        guest_started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        stop_guest = lambda do |_log|
          transcript_whole = matcher.consume(serial, elapsed: elapsed(guest_started))
          transcript_whole && !machine_end
        end
        @runner.run(argv, name: "qemu-#{accel}", deadline: deadline, success: stop_guest)
        matcher.drain(serial, elapsed: elapsed(guest_started))
        raise Error, 'QEMU exited before completing its transcript' unless matcher.done?
        report['state'] = 'passed'
      rescue CommandError => error
        report['state'] = error.result.fetch('state') == 'timed_out' ? 'timed_out' : 'failed'
        raise
      rescue TranscriptTimeout
        report['state'] = 'timed_out'
        raise
      rescue Error
        report['state'] = 'failed'
        raise
      ensure
        report['state'] = 'cancelled' if report['state'] == 'running'
        report['elapsed_seconds'] = elapsed(started)
        File.write(File.join(directory, 'report.json'), JSON.pretty_generate(report) + "\n")
      end
      report
    end

    private

    def elapsed(started)
      Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
    end
  end
end
