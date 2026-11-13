# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'digest'
require 'json'
require_relative 'abi'
require_relative 'data_volume'
require_relative 'block_image'
require_relative 'bounded_file'
require_relative 'erlang_apps'
require_relative 'error'
require_relative 'fiasco'
require_relative 'medium_image'
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
  # writes two sectors of its own; then, from the system domain, it restarts the
  # driver through the storage domain's driver-control facet. The driver runs in the storage domain, which the
  # development manifest gives the block unit, so the module, started in the system
  # domain, waits for storage@erxos to run erx_storage, loads its own object code
  # there and runs each step at that node over erpc; the system domain prints the
  # lines the step answers on the serial line, and the harness then reads the image
  # back.
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
  # by a newline (a carriage return before it is allowed) and each perhaps opened by
  # the command shell's PROMPT, which ends no line:
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
  #   blk: flushed                  the driver's flush, a virtio flush request,
  #                                 completed with a good status
  #   blk: control restart block ok the system domain restarted the driver through
  #                                 storage_ctl, the storage domain's driver-control
  #                                 facet, as the system shell does with
  #                                 erx_driver_ctl:restart(erx:cap(storage_ctl), block),
  #                                 and erx_blk names a new process at the storage node
  #   blk: control restart flux refused
  #                                 a unit the storage domain does not hold is refused
  #   blk: dev status ok            /dev holds one directory, the block device's, whose
  #                                 status names unit block, virtio,mmio and a holder
  #                                 domain
  #   blk: dev ctl reset ok         "reset" and a newline written to its ctl restarted
  #                                 the driver through the same facet: erx_blk names a
  #                                 new process
  #   blk: dev ctl bogus refused    any other word written to ctl fails with einval
  #   blk: read sector 0 again ok   the new driver reads sector 0's host pattern
  #   blk: done                     the last line; the harness ends the guest on it
  #
  # A step that fails is reported as "blk: read sector I failed", "blk: wrote
  # sector I failed" or a control line ending "failed" and what the step saw, and a guest whose driver did not start prints "blk: no driver"
  # and then "blk: done"; any line other than the above fails the suite. Other lines
  # the guest prints are not the test module's and are ignored.
  #
  # A second boot attaches a medium laid out by the ABI file's medium layout
  # (medium_image.rb) and starts the test module's `medium` entry, which drives the
  # block service's windows (erx_blk_service, erx_blk_window). For each window, in
  # MediumImage::ROLES order, the lines are
  #
  #   blk: window R sectors N       the window on role R's partition has N sectors
  #   blk: window R sector 0 holds host S
  #   blk: window R sector N-1 holds host E
  #                                 its first and last sectors hold the host's pattern
  #                                 of the medium's sectors S and E, so the window maps
  #                                 its sectors to the partition's, and only those; the
  #                                 data window has no "sector 0" line, since its first
  #                                 block holds /data's littlefs volume, which
  #                                 installation wrote there (fresh_medium)
  #   blk: window R sector N refused
  #                                 a read past its end is refused with erange
  #
  # then "blk: window data wrote sector N-1", the data window's last sector rewritten
  # with the guest's pattern of the medium sector it read there, "blk: window vault
  # write sector N refused", a write past the vault's end refused with erange, and
  # "blk: done". The harness then reads the medium back. medium_expected_lines holds
  # the sequence; a failed step prints "failed" in its line, a sector that holds
  # something else "holds other", and a guest without the service "blk: no windows".
  #
  # The power cut, M6's exit criterion (docs/plan.md): a fresh medium, two boots on it.
  # The first starts the module's `data_write`, which reaches /data's littlefs volume
  # (erx_lfs) through the file module, and prints
  #
  #   blk: data unsynced written    it opened /data/unsynced and wrote DATA_BYTES bytes,
  #                                 data_content(1), with neither sync nor close
  #   blk: data synced 10000 bytes  it opened /data/synced, wrote data_content(0) and
  #                                 file:sync returned ok
  #   blk: done
  #
  # and a process that never ends holds both files open, so nothing closes them. The
  # harness kills QEMU as soon as it reads "blk: done": that is the power cut. The second
  # boot, on the same medium, starts `data_read`, which prints
  #
  #   blk: data synced 10000 bytes md5 H
  #                                 /data/synced read back is DATA_BYTES bytes with the
  #                                 MD5 digest H of data_content(0), which the harness
  #                                 computes itself
  #   blk: data unsynced R          what is left of the unsynced file: "absent", or "N
  #                                 bytes prefix" when its N bytes begin data_content(1),
  #                                 or "N bytes other" when they do not; littlefs keeps
  #                                 no part of an unsynced write, so "absent" and "N
  #                                 bytes prefix" pass and the run's notes say which it
  #                                 saw, and "other", bytes nobody wrote, fails
  #   blk: done
  #
  # A step that fails prints "failed" in its line. Killing QEMU loses what the guest has
  # not yet handed the device, not what the device completed into the host's page cache
  # (TODO.md, the block service's flush).
  module BlockDevice
    SECTORS = 16
    TRANSPORT_VERSION = 2
    WRITE_SECTORS = [3, 7].freeze
    # The driver-control lines of the first boot (header), after its writes.
    CONTROL_LINES = ['blk: control restart block ok', 'blk: control restart flux refused',
                     'blk: dev status ok', 'blk: dev ctl reset ok', 'blk: dev ctl bogus refused',
                     'blk: read sector 0 again ok'].freeze
    DISK_NAME = 'disk.img'
    MEMORY_MIB = 512
    # Seconds the guest has, after its banner, to print the line "blk: done".
    GUEST_SECONDS = 120
    # The command shell's prompt (DEFAULT_PROMPT in erlang/apps/erx_shell/src/erx_shell.erl),
    # which ends no line and so may open the driver's next one; it is not part of the
    # driver's line.
    PROMPT = '% '
    # The test module, the guest directory its beam is packed in, and the kernel command
    # line words that start it after the release.
    GUEST_SOURCE = 'test/guest/block_device/erx_blk_check.erl'
    GUEST_MODULE = 'erx_blk_check'
    GUEST_PATH = '/test/blk'
    GUEST_ARGUMENTS = ['-pa', GUEST_PATH, '-run', GUEST_MODULE, 'main'].freeze
    MEDIUM_ARGUMENTS = ['-pa', GUEST_PATH, '-run', GUEST_MODULE, 'medium'].freeze
    MEDIUM_NAME = 'medium.img'
    WRITE_ARGUMENTS = ['-pa', GUEST_PATH, '-run', GUEST_MODULE, 'data_write'].freeze
    READ_ARGUMENTS = ['-pa', GUEST_PATH, '-run', GUEST_MODULE, 'data_read'].freeze
    # The length of each power-cut file: far past littlefs's inline limit, an eighth of a
    # block, so the synced file's data lives in blocks of its own.
    DATA_BYTES = 10_000
    # The second boot's report on the unsynced file: any outcome but bytes nobody wrote
    # passes (header).
    UNSYNCED_LINE = /\Ablk: data unsynced (?:absent|\d+ bytes prefix)\z/n
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
       'blk: flushed',
       *CONTROL_LINES,
       'blk: done']
    end

    # The lines of a good run of the medium boot.
    def medium_expected_lines
      windows = MediumImage.windows
      ["blk: capacity #{MediumImage.sectors} sectors",
       *windows.flat_map do |window|
         ["blk: window #{window.role} sectors #{window.sectors}",
          *("blk: window #{window.role} sector 0 holds host #{window.start}" unless window.role == :data),
          "blk: window #{window.role} sector #{window.sectors - 1} holds host #{window.last}",
          "blk: window #{window.role} sector #{window.sectors} refused"]
       end,
       "blk: window data wrote sector #{windows.find { |window| window.role == :data }.sectors - 1}",
       "blk: window vault write sector #{windows.find { |window| window.role == :vault }.sectors} refused",
       'blk: done']
    end

    # The power-cut files' content: DATA_BYTES bytes, byte I holding (I + seed) mod 251.
    def data_content(seed) = (0...DATA_BYTES).map { |index| (index + seed) % 251 }.pack('C*')

    # The lines of a good first power-cut boot, cut on its last.
    def write_expected_lines
      ['blk: data unsynced written', "blk: data synced #{DATA_BYTES} bytes", 'blk: done']
    end

    # The lines of a good second power-cut boot; one is a pattern every outcome that passes matches.
    def read_expected_lines
      ["blk: data synced #{DATA_BYTES} bytes md5 #{Digest::MD5.hexdigest(data_content(0))}", UNSYNCED_LINE, 'blk: done']
    end

    # What the second boot saw of the unsynced file, as its line says it, or nil.
    def unsynced_outcome(bytes)
      line = guest_lines(bytes).find { |guest| UNSYNCED_LINE.match?(guest) }
      line&.delete_prefix('blk: data unsynced ')
    end

    # What the medium must hold after a good run: the host's pattern in every window's
    # first and last sector but the data window's last, which the guest rewrote, and its
    # first, where the medium's fresh littlefs volume starts.
    def medium_expected_tags
      windows = MediumImage.windows
      data = windows.find { |window| window.role == :data }
      windows.flat_map { |window| [window.start, window.last] }
             .reject { |index| index == data.start }
             .to_h { |index| [index, index == data.last ? BlockImage::GUEST_TAG : BlockImage::HOST_TAG] }
    end

    # The bytes of the data volume's superblock pair, its first two blocks: both copies of
    # the root's metadata pair (erx_littlefs.h's 4096-byte blocks).
    VOLUME_PAIR_BYTES = 2 * 4096

    # Inverts every byte of the medium's data volume's superblock pair, so the volume's
    # files remain but its metadata no longer checks.
    def corrupt_volume(path)
      offset = MediumImage.constant('data_start') * MediumImage::SECTOR_BYTES
      File.open(path, File::RDWR | File::NOFOLLOW) do |medium|
        medium.binmode
        bytes = medium.pread(VOLUME_PAIR_BYTES, offset)
        medium.pwrite(bytes.bytes.map { |byte| byte ^ 0xff }.pack('C*'), offset)
      end
    end

    # The SHA-256 digest of the medium's data partition.
    def data_digest(path)
      offset = MediumImage.constant('data_start') * MediumImage::SECTOR_BYTES
      File.open(path, File::RDONLY | File::NOFOLLOW) do |medium|
        medium.binmode
        digest = Digest::SHA256.new
        (0...(MediumImage::DATA_SECTORS * MediumImage::SECTOR_BYTES)).step(1 << 20) do |at|
          digest << medium.pread(1 << 20, offset + at)
        end
        digest.hexdigest
      end
    end

    # The sectors of the medium that are not as expected, or nil when all are.
    def medium_image_difference(path)
      results = BlockImage.check(path: path, sectors: MediumImage.sectors, expected: medium_expected_tags,
                                 max_sectors: MediumImage::MAX_SECTORS)
      wrong = results.reject { |result| result.status == :match }.map { |result| "#{result.index} #{result.status}" }
      # The table's records too, byte for byte: the vault's refused write named the data
      # record's sector. check has already found path a bounded regular file.
      changed = File.open(path, File::RDONLY | File::NOFOLLOW) do |input|
        input.binmode
        MediumImage.records.reject { |sector, bytes| input.pread(bytes.bytesize, sector * BlockImage::SECTOR_BYTES) == bytes }
      end
      wrong += changed.keys.map { |sector| "#{sector} record" }
      return if wrong.empty?

      "medium sectors not as expected: #{wrong.join(', ')}"
    end

    # The driver's lines in the serial bytes, in order, without line endings, up to
    # and including the first "blk: done", each without a PROMPT that opened it;
    # whatever follows it is not judged. Serial bytes come from the guest and are
    # only compared here; a report quotes them only through quote.
    def guest_lines(bytes)
      lines = bytes.b.split("\n").map { |line| line.chomp("\r").delete_prefix(PROMPT) }
                   .select { |line| line.start_with?('blk: ') }
      done = lines.index('blk: done')
      done ? lines.first(done + 1) : lines
    end

    # What the image must hold after a good run: the host's pattern everywhere
    # except the sectors the guest wrote.
    def expected_tags
      (0...SECTORS).to_h { |index| [index, WRITE_SECTORS.include?(index) ? BlockImage::GUEST_TAG : BlockImage::HOST_TAG] }
    end

    # The first way the guest's lines differ from expected, or nil. An expected line
    # is a string the guest's must equal or a pattern it must match. The guest's text
    # is quoted escaped and cut short.
    def line_difference(bytes, expected: expected_lines)
      actual = guest_lines(bytes)
      index = (0...[actual.size, expected.size].max).find { |at| !line_matches?(expected[at], actual[at]) }
      return if index.nil?

      "driver line #{index + 1}: expected #{quote(expected[index])}, got #{quote(actual[index])}"
    end

    def line_matches?(expected, actual)
      expected.is_a?(Regexp) ? !actual.nil? && expected.match?(actual) : expected == actual
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
      return "a line matching #{line.source}" if line.is_a?(Regexp)

      %("#{Terminal.escape(line.byteslice(0, QUOTE_BYTES))}")
    end

    # The checkpoints of one boot: the usual banner with its test-image line, then the
    # test module's last line, within seconds of the banner.
    def checkpoints(seconds: GUEST_SECONDS)
      [*Qemu.boot_transcript(memory_mib: MEMORY_MIB, test_image: true),
       { name: 'block-done', pattern: /^(?:#{Regexp.escape(PROMPT)})?blk: done\r?\n/n, seconds: seconds }.freeze].freeze
    end

    # The kernel command line of a boot under accel: the harness's words for it, then
    # one erx.arg word for each argument that starts the test module.
    def command_line(accel, arguments: GUEST_ARGUMENTS)
      [ProductionImage::Run::COMMAND_LINES[accel], *arguments.map { |argument| "erx.arg=#{argument}" }].compact.join(' ')
    end

    class Run
      def initialize(root:, runner: Runner.new(owner_root: root, log_dir: File.join(root, 'build/logs')),
                     compiler: ENV.fetch('ERX_CLANG', ''), linker: ENV.fetch('ERX_LLD', ''), platform: Platform.development(root))
        @root = File.expand_path(root)
        @platform = platform
        @runner = runner
        @compiler = compiler
        @linker = linker
        @notes = []
      end

      # Boots the development image under each accelerator with one disk, then judges
      # the guest's lines and the image. Returns { "<accelerator>-1cpu" => 'passed' }
      # (the driver test runs one CPU); any disagreement raises.
      def call(accels:, jobs: 4, build: true)
        image = test_image_for(accels: accels, jobs: jobs, build: build)
        accels.to_h { |accel| ["#{accel}-1cpu", run_one(accel, image) && run_medium(accel, image) && run_power_cut(accel, image)] }
      end

      # What the runs saw that passes either way: the unsynced file's outcome.
      def notes = @notes.dup.freeze

      # The test image with the test module, which the driver domains suite boots too
      # (driver_domains.rb); build builds the kernel first.
      def test_image_for(accels:, jobs:, build:)
        unless accels.all? { |accel| %w[tcg hvf].include?(accel) }
          raise Error, 'the block device test image boots under tcg or hvf'
        end
        fiasco = Fiasco.new(root: @root, runner: @runner, compiler: @compiler)
        fiasco.build(jobs: jobs) if build
        test_image(fiasco)
      end

      # One boot of image on a fresh medium laid out by the ABI file, the test module
      # started with arguments, judged by its lines, of which the last is due within
      # seconds of the banner. Returns 'passed'; any disagreement raises.
      def boot_fresh_medium(accel, image, arguments:, expected:, seconds: GUEST_SECONDS)
        directory = run_directory(accel)
        disk = fresh_medium(directory)
        boot(accel, image, directory: directory, disk: disk, arguments: arguments, expected: expected, seconds: seconds) { nil }
      end

      # The corrupt volume (driver_domains.rb): a fresh medium whose /data a first boot
      # fills (data_write), whose volume's metadata the host then corrupts
      # (BlockDevice.corrupt_volume), and a boot on it that runs arguments. The data
      # partition must hold the same bytes after that boot as before it: a mount never
      # writes to a volume it could not mount. Each boot keeps its serial log in a
      # directory of its own beside the medium.
      def boot_corrupt_medium(accel, image, arguments:, expected:, seconds:)
        directory = run_directory(accel)
        disk = fresh_medium(directory)
        boot(accel, image, directory: File.join(directory, 'fill'), disk: disk, arguments: WRITE_ARGUMENTS,
                           expected: BlockDevice.write_expected_lines) { nil }
        BlockDevice.corrupt_volume(disk)
        before = BlockDevice.data_digest(disk)
        boot(accel, image, directory: File.join(directory, 'corrupt'), disk: disk, arguments: arguments, expected: expected,
                           seconds: seconds) { BlockDevice.data_digest(disk) == before ? nil : 'the corrupt volume changed' }
      end

      private

      # The raw disk, driven through erx_blk itself.
      def run_one(accel, image)
        directory = run_directory(accel)
        disk = BlockImage.create(directory: directory, name: DISK_NAME, sectors: SECTORS)
        boot(accel, image, directory: directory, disk: disk, arguments: GUEST_ARGUMENTS,
                           expected: BlockDevice.expected_lines) { BlockDevice.image_difference(disk) }
      end

      # The medium laid out by the ABI file, driven through the block service's windows.
      def run_medium(accel, image)
        directory = run_directory(accel)
        disk = fresh_medium(directory)
        boot(accel, image, directory: directory, disk: disk, arguments: MEDIUM_ARGUMENTS,
                           expected: BlockDevice.medium_expected_lines) { BlockDevice.medium_image_difference(disk) }
      end

      # The power cut: a fresh medium, a boot that writes and syncs a file under /data and
      # is killed on its last line, and a boot on the same medium that reads it back. Each
      # boot keeps its serial log in a directory of its own beside the medium.
      def run_power_cut(accel, image)
        directory = run_directory(accel)
        disk = fresh_medium(directory)
        boot(accel, image, directory: File.join(directory, 'write'), disk: disk, arguments: WRITE_ARGUMENTS,
                           expected: BlockDevice.write_expected_lines) { nil }
        boot(accel, image, directory: File.join(directory, 'read'), disk: disk, arguments: READ_ARGUMENTS,
                           expected: BlockDevice.read_expected_lines) { nil }
        outcome = BlockDevice.unsynced_outcome(read_serial(File.join(directory, 'read', 'serial.log')))
        @notes << "#{accel}: the unsynced file after the power cut: #{outcome}"
        'passed'
      end

      # A medium laid out by the ABI file, as installation leaves it, in directory: the
      # host's pattern in each window's first and last sector but the data window's first,
      # where the data partition's fresh littlefs volume starts (DataVolume), since the
      # guest's mount never formats.
      def fresh_medium(directory)
        volume = DataVolume.format(root: @root, runner: @runner, compiler: @compiler, directory: directory,
                                   data_sectors: MediumImage::DATA_SECTORS)
        pieces = MediumImage.probes(MediumImage::DATA_SECTORS).merge(DataVolume.pieces(volume))
        MediumImage.create(directory: directory, name: MEDIUM_NAME, pieces: pieces)
      end

      def run_directory(accel)
        OutputDirectory.prepare(root: @root, path: File.join(@root, 'build/block-device',
                                                             "#{accel}-#{Process.pid}-#{Random.bytes(8).unpack1('H*')}"),
                                mode: 0o700)
      end

      # One boot with disk attached, judged by its lines and then by the block that
      # reads the disk back.
      def boot(accel, image, directory:, disk:, arguments:, expected:, seconds: GUEST_SECONDS)
        serial = File.join(directory, 'serial.log')
        begin
          Qemu.new(root: @root, runner: @runner).run(platform: @platform, accel: accel, image: image, memory_mib: MEMORY_MIB, directory: directory,
                                                     checkpoints: BlockDevice.checkpoints(seconds: seconds), disks: [QemuPlan::Disk.new(path: disk)],
                                                     command_line: BlockDevice.command_line(accel, arguments: arguments))
        rescue TranscriptTimeout => error
          # A driver that fails stops printing before "blk: done": say which step.
          raise Error, "block device on #{accel}: #{error.message}; " \
                       "#{BlockDevice.line_difference(read_serial(serial), expected: expected)}"
        end
        problem = BlockDevice.line_difference(read_serial(serial), expected: expected) || yield
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
        ProductionImage.new(root: @root, runner: @runner, compiler: @compiler, linker: @linker,
                            machine: ProductionImage::Machine.development(@platform), fiasco: fiasco)
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
