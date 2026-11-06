# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'digest'
require 'json'
require_relative 'abi'
require_relative 'block_image'
require_relative 'bounded_file'
require_relative 'erlang_apps'
require_relative 'error'
require_relative 'fiasco'
require_relative 'oracle'
require_relative 'output_directory'
require_relative 'production_image'
require_relative 'qemu'
require_relative 'runner'
require_relative 'runtime'

module Erx
  # The virtio-mmio block driver end to end on QEMU virt: the harness attaches a raw
  # disk image whose sectors hold known patterns (block_image.rb), the system boots,
  # and a test module, erx_blk_check (GUEST_SOURCE), drives the block driver through
  # its public calls: it reads the sectors, is refused a read past the end, and
  # writes two sectors of its own. It reports each step on the serial line, and the
  # harness then reads the image back.
  #
  # The module is test code, so it reaches the guest only in a test image: the
  # harness compiles it with the stock oracle's erlc, adds the beam to the system
  # release under GUEST_PATH through ProductionImage's test entry point, which marks
  # the archive so the kernel's banner says it is a test image, and starts it with
  # the kernel command line's erx.arg words `-pa GUEST_PATH -run erx_blk_check main`.
  # Checks::TEST_IMAGE_BUILDERS holds that this file and the oracle's QEMU run alone
  # build test images.
  #
  # The guest's lines, in this order and no others starting with "blk: ", each ended
  # by a newline (a carriage return before it is allowed):
  #
  #   blk: transport version 2      the device's virtio-mmio transport is version
  #                                 TRANSPORT_VERSION, the one the driver runs
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
  # sector I failed", and a guest whose driver did not start prints "blk: no driver"
  # and then "blk: done"; any line other than the above fails the suite. Other lines
  # the guest prints are not the test module's and are ignored.
  module BlockDevice
    SECTORS = 16
    TRANSPORT_VERSION = 2
    WRITE_SECTORS = [3, 7].freeze
    DISK_NAME = 'disk.img'
    MEMORY_MIB = 512
    # Seconds the guest has, after its banner, to print the line "blk: done".
    GUEST_SECONDS = 120
    # True once the block driver starts on the suite's disk and the test module prints
    # the lines above; while it is false the suite reports its cell pending (TODO.md).
    DRIVER_LANDED = false
    # The test module, the guest directory its beam is packed in, and the kernel command
    # line words that start it after the release.
    GUEST_SOURCE = 'test/guest/block_device/erx_blk_check.erl'
    GUEST_MODULE = 'erx_blk_check'
    GUEST_PATH = '/test/blk'
    GUEST_ARGUMENTS = ['-pa', GUEST_PATH, '-run', GUEST_MODULE, 'main'].freeze
    ERLC_DEADLINE = 120
    # The most serial text read back, and the most of a guest line quoted in a report.
    SERIAL_BYTES = 1 << 20
    QUOTE_BYTES = 120

    module_function

    # The driver's lines for a good run.
    def expected_lines
      ["blk: transport version #{TRANSPORT_VERSION}",
       "blk: capacity #{SECTORS} sectors",
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

    # The checkpoints of one boot: the usual banner with its test-image line, then the
    # test module's last line.
    def checkpoints
      [*Qemu.boot_transcript(memory_mib: MEMORY_MIB, test_image: true),
       { name: 'block-done', pattern: /^blk: done\r?\n/n, seconds: GUEST_SECONDS }.freeze].freeze
    end

    # The kernel command line of a boot under accel: the harness's words for it, then
    # one erx.arg word for each argument that starts the test module.
    def command_line(accel)
      [ProductionImage::Run::COMMAND_LINES[accel], *GUEST_ARGUMENTS.map { |argument| "erx.arg=#{argument}" }].compact.join(' ')
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
        image = test_image(fiasco)
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
                                                     checkpoints: BlockDevice.checkpoints, disks: [QemuPlan::Disk.new(path: disk)],
                                                     command_line: BlockDevice.command_line(accel))
        rescue TranscriptTimeout => error
          # A driver that fails stops printing before "blk: done": say which step.
          raise Error, "block device on #{accel}: #{error.message}; #{BlockDevice.line_difference(read_serial(serial))}"
        end
        problem = BlockDevice.line_difference(read_serial(serial)) || BlockDevice.image_difference(disk)
        raise Error, "block device on #{accel}: #{problem}" if problem

        'passed'
      end

      def read_serial(path) = BoundedFile.read(path, maximum: SERIAL_BYTES)

      # The production image with the test module added to its system release, as a
      # system file with a compiled receipt naming its source.
      def test_image(fiasco)
        directory = ProductionImage.clear_directory(root: @root, path: File.join(@root, 'build/block-device/image'))
        cleared = ProductionImage.clear_directory(root: @root, path: File.join(@root, 'build/block-device/guest-code'))
        code = OutputDirectory.prepare(root: @root, path: cleared)
        beam = compile(code)
        receipt = File.join(code, 'receipt.json')
        File.write(receipt, JSON.pretty_generate('version' => 1, 'kind' => 'compiled', 'artifact' => reference(beam),
                                                 'sources' => [reference(source)]))
        codec = ABI::Codec.new(ABI::Generator.plan(root: @root).schema)
        entry = { 'path' => "system#{GUEST_PATH}/#{GUEST_MODULE}.beam", 'kind' => codec.member('entry_kind', 'file'),
                  'flags' => codec.member('entry_flags', 'system'), 'id' => 'block-device-check', 'artifact' => beam,
                  'receipt' => receipt }
        added = ProductionImage::Added.new(entries: [entry], inputs: [beam, source, receipt], imports: {})
        ProductionImage.new(root: @root, runner: @runner, compiler: @compiler, linker: @linker, fiasco: fiasco)
                       .build_test_image(directory: directory, added: added).single
      end

      # The test module's beam, compiled into directory by the stock oracle's erlc with
      # the flags of erXos's own applications.
      def compile(directory)
        erlc = File.join(File.dirname(Oracle.new(root: @root, runner: @runner).erl_path(Runtime::HOST_OTP_FLAVOUR)), 'erlc')
        @runner.run([erlc, *ErlangApps::FLAGS, '-o', directory, source], name: 'erlc-block-device-check',
                                                                          deadline: ERLC_DEADLINE, chdir: @root,
                                                                          env: Oracle::CLEAN_ERLANG_ENV)
        File.join(directory, "#{GUEST_MODULE}.beam")
      end

      def source = File.join(@root, GUEST_SOURCE)

      def reference(path) = { 'path' => path.delete_prefix("#{@root}/"), 'sha256' => Digest::SHA256.file(path).hexdigest }
    end
  end
end
