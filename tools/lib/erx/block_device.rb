# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require_relative 'block_image'
require_relative 'bounded_file'
require_relative 'error'
require_relative 'fiasco'
require_relative 'output_directory'
require_relative 'production_image'
require_relative 'qemu'
require_relative 'runner'

module Erx
  # The virtio-mmio block driver end to end on QEMU virt: the harness attaches a raw
  # disk image whose sectors hold known patterns (block_image.rb), the system boots,
  # and its block driver reads the sectors, is refused a read past the end, and
  # writes two sectors of its own. The driver reports each step on the serial line,
  # and the harness then reads the image back.
  #
  # The guest's lines, in this order and no others starting with "blk: ", each ended
  # by a newline (a carriage return before it is allowed):
  #
  #   blk: capacity 16 sectors      the device reports SECTORS sectors of 512 bytes
  #   blk: read sector I ok         for I in 0 ... SECTORS - 1, in order: the sector
  #                                 read back holds BlockImage.pattern(I, HOST_TAG)
  #   blk: read sector 16 refused   a read of sector SECTORS is refused, with the
  #                                 device untouched
  #   blk: wrote sector I           for I in WRITE_SECTORS, in order: the driver wrote
  #                                 BlockImage.pattern(I, GUEST_TAG) and the device
  #                                 completed the request with a good status
  #   blk: done                     the last line; the harness ends the guest on it
  #
  # A step that fails is reported as "blk: read sector I failed" or "blk: wrote
  # sector I failed"; any line other than the above fails the suite. Other lines the
  # guest prints are not the driver's and are ignored.
  module BlockDevice
    SECTORS = 16
    WRITE_SECTORS = [3, 7].freeze
    DISK_NAME = 'disk.img'
    MEMORY_MIB = 512
    # Seconds the guest has, after its banner, to print the line "blk: done".
    GUEST_SECONDS = 120
    # False until the block driver prints the lines above; the suite reports its cell
    # pending while it is false, and the driver's landing sets it.
    DRIVER_LANDED = false
    # The most serial text read back, and the most of a guest line quoted in a report.
    SERIAL_BYTES = 1 << 20
    QUOTE_BYTES = 120

    module_function

    # The driver's lines for a good run.
    def expected_lines
      ["blk: capacity #{SECTORS} sectors",
       *(0...SECTORS).map { |index| "blk: read sector #{index} ok" },
       "blk: read sector #{SECTORS} refused",
       *WRITE_SECTORS.map { |index| "blk: wrote sector #{index}" },
       'blk: done']
    end

    # The driver's lines in the serial bytes, in order, without line endings, up to
    # and including the first "blk: done"; whatever follows it is not judged. Serial
    # bytes come from the guest and are only compared here; a report quotes them
    # only through quote.
    def guest_lines(bytes)
      lines = bytes.b.split("\n").map { |line| line.chomp("\r") }.select { |line| line.start_with?('blk: ') }
      done = lines.index('blk: done')
      done ? lines.first(done + 1) : lines
    end

    # What the image must hold after a good run: the host's pattern everywhere
    # except the sectors the guest wrote.
    def expected_tags
      (0...SECTORS).to_h { |index| [index, WRITE_SECTORS.include?(index) ? BlockImage::GUEST_TAG : BlockImage::HOST_TAG] }
    end

    # The first way the guest's lines differ from expected_lines, or nil. The
    # guest's text is quoted escaped and cut short.
    def line_difference(bytes)
      actual = guest_lines(bytes)
      expected = expected_lines
      index = (0...[actual.size, expected.size].max).find { |at| actual[at] != expected[at] }
      return if index.nil?

      "driver line #{index + 1}: expected #{quote(expected[index])}, got #{quote(actual[index])}"
    end

    # The sectors of the image that are not as expected, or nil when all are.
    def image_difference(path)
      results = BlockImage.check(path: path, sectors: SECTORS, expected: expected_tags)
      wrong = results.reject { |result| result.status == :match }
      return if wrong.empty?

      "disk sectors not as expected: #{wrong.map { |result| "#{result.index} #{result.status}" }.join(', ')}"
    end

    def quote(line)
      return 'no line' if line.nil?

      %("#{Terminal.escape(line.byteslice(0, QUOTE_BYTES))}")
    end

    # The checkpoints of one boot: the usual banner, then the driver's last line.
    def checkpoints
      [*Qemu.boot_transcript(memory_mib: MEMORY_MIB),
       { name: 'block-done', pattern: /^blk: done\r?\n/n, seconds: GUEST_SECONDS }.freeze].freeze
    end

    class Run
      def initialize(root:, runner: Runner.new(owner_root: root, log_dir: File.join(root, 'build/logs')),
                     compiler: ENV.fetch('ERX_CLANG', ''), linker: ENV.fetch('ERX_LLD', ''))
        @root = File.expand_path(root)
        @runner = runner
        @compiler = compiler
        @linker = linker
      end

      # Boots the development image under each accelerator with one disk, then judges
      # the guest's lines and the image. Returns { "<accelerator>-1cpu" => 'passed' }
      # (the driver test runs one CPU); any disagreement raises.
      def call(accels:, jobs: 4, build: true)
        unless accels.all? { |accel| %w[tcg hvf].include?(accel) }
          raise Error, 'the block device suite runs under tcg or hvf'
        end
        fiasco = Fiasco.new(root: @root, runner: @runner, compiler: @compiler)
        fiasco.build(jobs: jobs) if build
        image = development_image(fiasco)
        accels.to_h { |accel| ["#{accel}-1cpu", run_one(accel, image)] }
      end

      private

      def run_one(accel, image)
        directory = OutputDirectory.prepare(root: @root, path: File.join(@root, 'build/block-device',
                                                                         "#{accel}-#{Process.pid}-#{Random.bytes(8).unpack1('H*')}"),
                                            mode: 0o700)
        disk = BlockImage.create(directory: directory, name: DISK_NAME, sectors: SECTORS)
        serial = File.join(directory, 'serial.log')
        begin
          Qemu.new(root: @root, runner: @runner).run(accel: accel, image: image, memory_mib: MEMORY_MIB, directory: directory,
                                                     checkpoints: BlockDevice.checkpoints, disks: [QemuPlan::Disk.new(path: disk)])
        rescue TranscriptTimeout => error
          # A driver that fails stops printing before "blk: done": say which step.
          raise Error, "block device on #{accel}: #{error.message}; #{BlockDevice.line_difference(read_serial(serial))}"
        end
        problem = BlockDevice.line_difference(read_serial(serial)) || BlockDevice.image_difference(disk)
        raise Error, "block device on #{accel}: #{problem}" if problem

        'passed'
      end

      def read_serial(path) = BoundedFile.read(path, maximum: SERIAL_BYTES)

      def development_image(fiasco)
        directory = ProductionImage.clear_directory(root: @root, path: File.join(@root, 'build/block-device/image'))
        ProductionImage.new(root: @root, runner: @runner, compiler: @compiler, linker: @linker, fiasco: fiasco)
                       .build(directory: directory).single
      end
    end
  end
end
