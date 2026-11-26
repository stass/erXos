# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'digest'
require 'fileutils'
require 'json'
require 'tmpdir'
require_relative 'error'
require_relative 'fsimg'
require_relative 'data_volume'
require_relative 'pi_medium'
require_relative 'bl31'
require_relative 'card_settings'
require_relative 'board_tree'
require_relative 'boot_partition_settings'
require_relative 'build_kind'
require_relative 'bounded_file'
require_relative 'build_path'
require_relative 'dependencies'
require_relative 'device_kinds'
require_relative 'output_directory'
require_relative 'platform'
require_relative 'qemu'
require_relative 'source_revision'

module Erx
  # The Raspberry Pi 4's medium, the production image's for a board the firmware boots
  # (ProductionImage#build_medium): written beside the image, boot/ holds the boot
  # partition's files and serves as the firmware's network boot (TFTP) root; sdcard.img
  # is the card, ready to write, laid out as abi/medium.txt's medium (PiMedium), whose
  # slot A holds the same files in its FAT32, the system release's EROFS image after
  # them, and whose data partition holds a fresh littlefs volume; sdcard.img.xz is the
  # card xz-compressed (compress), the form it is downloaded and written in; and
  # sdcard.img.receipt.json is their build record
  # (docs/design-fiasco.md, "The Raspberry Pi 4"; docs/design-platforms.md, "Firmware").
  # The files are the firmware, unmodified, with its license; config.txt, written from
  # the platform record; on a development card, cmdline.txt, the kernel command line with the
  # host link's word; the board's device tree, with its one marked edit, its source
  # and Linux's GPL-2.0 text (BoardTree), and the overlays config.txt names; TF-A's BL31
  # as the armstub, with its license; and the production image's bootable file as
  # kernel8.img.
  #
  # The card and its build record are what the website offers for the board
  # (site/README.md), so the record is fit to publish: it names the erXos commit the card
  # was built from and whether the tree had changes, and each host tool by its version
  # line alone, never by a path, which may carry a user's name. The website refuses a
  # record of another commit, of a changed tree, or one that holds an absolute path
  # (check_record); packing does not, since a self-built tool's version line may name
  # the directory it was built in, and such a card still serves its builder.
  #
  # Every name in the layout is one of this module's own, so nothing a caller passes
  # chooses where a file lands. The three entries are written in a fresh work directory
  # inside the image's directory, then renamed beside the image; the image's directory
  # must not hold any of them already.
  module BootPartition
    KERNEL = PiMedium::BOOT_FILE
    ARMSTUB = 'bl31.bin'
    CONFIG = 'config.txt'
    # The kernel command line, by the firmware's default name (config.txt's `cmdline`).
    CMDLINE = 'cmdline.txt'
    ARMSTUB_LICENSE = 'LICENSE.tf-a'
    # A file of the layout whose bytes are given, not read from a path.
    Text = Data.define(:bytes)
    # The firmware's files, by deps.lock pin; each keeps its pinned file name.
    FIRMWARE = %w[rpi-firmware-start4 rpi-firmware-fixup4 rpi-firmware-license].freeze
    # A file name of the layout: one name, or one under overlays/.
    NAME = %r{\A(?:overlays/)?[A-Za-z0-9][A-Za-z0-9_.,+-]*\z}
    # No file is larger than the partition that holds it, so the partition's size bounds each
    # read. What fits in all, with the FATs and directories, is for fsimg to refuse when the
    # volume fills; PiMedium.check_slot reads the result back.
    MAX_FILE = PiMedium::SLOT_FAT_BYTES
    # The medium's four entries beside the image: the partition's files, the card's disk
    # image, the image compressed, and their build record.
    PARTITION = 'boot'
    IMAGE = 'sdcard.img'
    COMPRESSED = 'sdcard.img.xz'
    RECORD = 'sdcard.img.receipt.json'
    ENTRIES = [PARTITION, IMAGE, COMPRESSED, RECORD].freeze
    # A set's build record, beside its boot/ (write_set), and what a set's directory holds.
    SET_RECORD = 'boot.receipt.json'
    SET_ENTRIES = [PARTITION, SET_RECORD].freeze
    # How the card is compressed. One fixed preset and one thread, so xz writes one stream
    # of one block, and XZ_ENVIRONMENT unsets the variables xz reads options from before its
    # command line, so the bytes depend only on the card and xz's encoder. -9's 64 MiB
    # dictionary reaches repeats far apart in a card; reading it back takes 65 MiB. xz makes
    # a card, which is mostly blank, less than half what gzip does, and Raspberry Pi Imager
    # writes a .img.xz as it is.
    XZ_ARGUMENTS = %w[xz --format=xz --check=crc64 -9 --threads=1 --stdout].freeze
    XZ_ENVIRONMENT = { 'XZ_DEFAULTS' => nil, 'XZ_OPT' => nil }.freeze
    # Far above what xz takes for a card, most of which is zeros: some 6 s for 718 MiB of
    # zeros on an Apple Silicon Mac.
    XZ_DEADLINE = 900
    # The most bytes a reader takes of a build record, a few kilobytes of names, pins and
    # digests; anything far larger is not one.
    RECORD_BYTES = 1024 * 1024
    # The memory the firmware reports: total_mem makes any Pi 4 report the smallest
    # board's 1 GB, of which gpu_mem goes to the VideoCore, so the ARM's RAM is the same
    # on every board and on QEMU's 1 GB model, where the record's ram_bytes and
    # fiasco_reserve were measured. A larger board runs on that 1 GB.
    TOTAL_MEM_MIB = 1024
    GPU_MEM_MIB = 76

    # What write left in the image's directory: path, the card's image (the medium, as
    # ReleaseMedium::Written#path is QEMU's); compressed, the image compressed (compress);
    # files, the partition's directory; record, their build record.
    Written = Data.define(:path, :compressed, :files, :record)
    # What write_set left in a set's directory: files, the partition's directory, and
    # record, their build record.
    WrittenSet = Data.define(:files, :record)

    module_function

    # Whether platform's medium is a boot partition: a board whose firmware boots the
    # image from one, which is a board with a tree of its own (BoardTree::BOARDS).
    def boot_partition_medium?(platform) = BoardTree::BOARDS.key?(platform.name)

    # config.txt for platform and build_kind (development or release), setting by setting:
    # * arm_64bit, kernel, kernel_address, armstub: a 64-bit kernel8.img, loaded where the
    #   model's loader puts it and bootstrap is linked, entered through BL31.
    # * enable_uart: the console, the mini UART, with its line set and the core clock it
    #   divides from pinned, so its divisor holds for the later stages. The firmware puts
    #   GPIO 14 and 15 in ALT5 whatever gpio= lines say; the map's console rows agree.
    # * init_uart_clock: the PL011s' clock from the record, for UART3, the host link.
    # * core_freq, core_freq_fixed: the header map's core clock, which the I2C and SPI
    #   controllers divide, fixed so the rate their drivers divide holds (core_lines).
    # * arm_freq, force_turbo: the record's ARM clock, held (CardSettings): no system run on
    #   the board asks the firmware for a clock, and without force_turbo the firmware's own
    #   scaling would choose one.
    # * total_mem, gpu_mem: the record's RAM.
    # * framebuffer_depth, framebuffer_ignore_alpha, max_framebuffers: one 32-bit
    #   framebuffer with its alpha channel ignored, so the root finds at most one
    #   simple-framebuffer node, not one per HDMI port (design-device-tree.md).
    # * disable_overscan: the framebuffer fills the screen. The firmware otherwise keeps
    #   48 pixels of overscan on each edge of an HD CEA mode, so a 1920x1080 screen's
    #   framebuffer would be 1824x984 inside a black border (design-device-tree.md).
    # * development_lines: the firmware's own boot log on the console and, for a map with
    #   jtag rows, the ARM's JTAG, on a development card only.
    # * a dtoverlay line for each overlay the board's tree carries.
    # * pin_lines: the header map's device rows. The firmware sets no pins from an overlay,
    #   so an overlay's device gets its pins from these lines alone. The on-board rows give
    #   no line: the firmware leaves GPIO 30 and 31 inputs whatever a line asks, so the root
    #   sets every on-board row at boot (docs/design-header-io.md, "On-board pins").
    def config_txt(platform, overlays:, build_kind:)
      table = platform.pins
      raise Error, "#{platform.record_path}: the boot partition needs the record's pins" if table.nil?

      <<~CONFIG + core_lines(table) + development_lines(build_kind) + overlays.map { |name| "dtoverlay=#{name}\n" }.join + pin_lines(table)
        # erXos boot partition for #{platform.name}, written by tools/lib/erx/boot_partition.rb.
        arm_64bit=1
        kernel=#{KERNEL}
        kernel_address=0x#{QemuPlan::MACHINES.fetch(platform.name).loads.image.to_s(16)}
        armstub=#{ARMSTUB}
        #{arm_clock_lines(platform)}#{setting_lines(table, build_kind)}init_uart_clock=#{pl011_clock(platform)}
        total_mem=#{total_mem_mib(platform)}
        gpu_mem=#{GPU_MEM_MIB}
        framebuffer_depth=32
        framebuffer_ignore_alpha=1
        max_framebuffers=1
        disable_overscan=1
      CONFIG
    end

    # The layout's cmdline.txt entry for platform and build_kind, or no entry for a card with
    # no command line. The firmware reads the file and the board's boot takes the line from
    # /chosen/bootargs, where the root reads its erx. words (liberx/backend/fiasco/boot_args.c;
    # the firmware's own words are ignored there). A development card whose platform has a host
    # link UART asks for it, with the word QEMU's plan adds with its second serial line; a
    # release card has no command line and so no host link (docs/design-live.md, "The host
    # link from a board"). The word ends the file with no newline: the root's parser splits on
    # spaces alone, so a newline the firmware kept in the line would make "erx.hostlink=1\n" a
    # malformed word and refuse the boot.
    def command_line_entry(platform, build_kind)
      return {} unless BuildKind.development?(build_kind) && platform.record['hostlink']

      { CMDLINE => Text.new(QemuPlan::HOSTLINK_WORD) }
    end

    # total_mem, once the record's ram_bytes is what it leaves the ARM; a record measured
    # at another size is refused.
    def total_mem_mib(platform)
      ram = platform.record.fetch('ram_bytes')
      unless ram == (TOTAL_MEM_MIB - GPU_MEM_MIB) * 1024 * 1024
        raise Error, "#{platform.record_path}: ram_bytes #{ram} is not total_mem #{TOTAL_MEM_MIB} MiB less gpu_mem #{GPU_MEM_MIB} MiB"
      end

      TOTAL_MEM_MIB
    end

    # The ARM clock lines for platform's record: arm_freq in MHz, the unit config.txt takes,
    # held by force_turbo; none for a record that names no clock (CardSettings).
    def arm_clock_lines(platform)
      hz = CardSettings.clock_hz(platform.record, label: platform.record_path) or return ''

      "arm_freq=#{hz / 1_000_000}\nforce_turbo=1\n"
    end

    # The firmware's own boot log on the console (uart_2ndstage), on a development card only.
    def development_lines(build_kind) = BuildKind.development?(build_kind) ? "uart_2ndstage=1\n" : ''

    # The settings of the boot description's table (FIRMWARE_SETTINGS) whose pins are rows
    # of the pin table, each on the kinds of card it lists: on the Raspberry Pi 4 enable_uart
    # on every card, and enable_jtag_gpio, the ARM's JTAG for a probe when the serial log
    # cannot locate a hang, on a development card alone, so a release card's jtag rows are
    # pins nobody sets.
    def setting_lines(table, build_kind)
      kind = BuildKind.fetch(build_kind)
      table.settings.select { |setting| setting.kinds.include?(kind) }.map { |setting| "#{setting.name}=1\n" }.join
    end

    # core_freq in MHz, the unit config.txt takes, and core_freq_fixed, for a table whose
    # devices divide the core clock (PinTable::Table#core_clock, whole MHz).
    def core_lines(table)
      clock = table.core_clock
      return '' if clock.nil?

      "core_freq=#{clock / 1_000_000}\ncore_freq_fixed=1\n"
    end

    # The pull attribute of a gpio= line; none for a row that names no pull.
    PULL_ATTRIBUTES = { nil => '', none: ',pn', up: ',pu', down: ',pd' }.freeze

    # One gpio=N=aK,pX line for each run of consecutive device rows of one alternate and
    # pull, written gpio=N-M=... for a run of more than one pin: the header device rows'
    # default settings. A gpio= line sets an alternate, so a header device row of in or out
    # is refused.
    def pin_lines(table)
      rows = table.controllers.flat_map(&:header_device_rows).map { |row| [row.gpio, row.setting] }
      gpio, plain = rows.find { |_gpio, setting| setting.alternate.nil? }
      raise Error, "GPIO #{gpio}: config.txt's gpio= lines set a signal, not #{plain.function}" if plain

      runs = rows.slice_when do |(left, left_setting), (right, right_setting)|
        right != left + 1 || [right_setting.alternate, right_setting.pull] != [left_setting.alternate, left_setting.pull]
      end
      runs.map do |run|
        pins = run.size == 1 ? run.first[0].to_s : "#{run.first[0]}-#{run.last[0]}"
        setting = run.first[1]
        "gpio=#{pins}=a#{setting.alternate}#{PULL_ATTRIBUTES.fetch(setting.pull)}\n"
      end.join
    end

    # The one clock of the record's PL011s, which config.txt's init_uart_clock sets for
    # all of them. A record whose PL011s disagree, or that has none, is refused.
    def pl011_clock(platform)
      pl011 = DeviceKinds.uart_compatible(DeviceKinds::PL011)
      clocks = platform.record.fetch('units').flat_map { |unit| unit.fetch('devices') }
                       .select { |device| device['compatible'] == pl011 }.map { |device| device['clock'] }.uniq
      raise Error, "#{platform.record_path}: the PL011s need one clock, not #{clocks.inspect}" unless
        clocks.size == 1 && clocks[0].is_a?(Integer) && clocks[0].positive?

      clocks[0]
    end

    # The layout as a map from each file's name in the partition to its source path,
    # or to its Text for config.txt and cmdline.txt; firmware maps each firmware file's name to its path.
    # Pure.
    def plan(platform:, build_kind:, bootable:, bl31:, bl31_license:, tree:, firmware:)
      board = BoardTree.board(platform)
      own = { KERNEL => bootable, ARMSTUB => bl31, ARMSTUB_LICENSE => bl31_license,
              CONFIG => Text.new(config_txt(platform, overlays: tree.overlays.keys, build_kind: build_kind)),
              **command_line_entry(platform, build_kind),
              board.file => tree.board, BoardTree.source_file(board) => tree.source,
              BoardTree::LICENSE_FILE => tree.license,
              **tree.overlays.to_h { |name, path| ["overlays/#{name}.dtbo", path] } }
      clash = own.keys & firmware.keys
      raise Error, "boot partition: the firmware's #{clash.join(', ')} would replace a file of the layout" unless clash.empty?

      own.merge(firmware)
    end

    # Writes plan into directory, an existing directory under root that holds none of
    # ENTRIES: the files under boot/; the card (PiMedium), whose slot A's FAT32 holds them
    # with each root name that fits 8.3 stored as its own short name, which is all the
    # boot ROM reads, followed by erofs, the release's EROFS image (nothing when erofs is
    # nil), and whose data partition holds volume, a fresh littlefs volume of
    # MediumImage::PACKED_DATA_SECTORS sectors (DataVolume.format); the card compressed (compress);
    # and record, the inputs' build record, with the SHA-256 of each file, the EROFS image,
    # the volume and the card added.
    def write(root:, directory:, plan:, record:, runner:, fsimg:, erofs:, volume:)
      directory = staged(root: root, directory: directory, plan: plan, entries: ENTRIES, record_name: RECORD) do |work, files, written|
        image = PiMedium.write(directory: work, name: IMAGE, files: files, names: plan.keys.map { |name| name.split('/').first }.uniq,
                               erofs: erofs, volume: volume, runner: runner, fsimg: fsimg)
        compress(image, to: File.join(work, COMPRESSED), runner: runner)
        pieces = [erofs, volume.path].compact.to_h { |piece| [File.basename(piece), Digest::SHA256.file(piece).hexdigest] }
        receipt(record, image: image, files: written, pieces: pieces)
      end
      Written.new(path: File.join(directory, IMAGE), compressed: File.join(directory, COMPRESSED),
                  files: File.join(directory, PARTITION), record: File.join(directory, RECORD))
    end

    # Writes plan into directory, as write does, as the files under boot/ and their build
    # record alone, with no card, volume or compression: a bench set
    # (docs/design-bench.md, "The bench image's boot set").
    def write_set(root:, directory:, plan:, record:)
      directory = staged(root: root, directory: directory, plan: plan, entries: SET_ENTRIES, record_name: SET_RECORD) do |_work, _files, written|
        receipt(record, image: nil, files: written, pieces: {})
      end
      WrittenSet.new(files: File.join(directory, PARTITION), record: File.join(directory, SET_RECORD))
    end

    # The one way write and write_set place their entries. plan's names must be the
    # layout's, and directory an existing one under root that holds none of entries.
    # plan's files go under boot/ of a fresh work directory beside them, each refused if
    # it holds the build's path. The block gets the work directory, boot/ and each file's
    # SHA-256, makes what else the entries hold and answers the receipt, which is written
    # as record_name. Only then do entries move into directory. Answers directory as
    # checked, resolved within root.
    def staged(root:, directory:, plan:, entries:, record_name:)
      plan.each_key { |name| raise Error, "boot partition: #{name.inspect} is not a file name of the layout" unless NAME.match?(name) }
      directory = OutputDirectory.check(root: root, path: directory)
      raise Error, "boot partition: #{directory} is not a directory" unless File.directory?(directory)

      taken = entries.select { |name| File.exist?(File.join(directory, name)) || File.symlink?(File.join(directory, name)) }
      raise Error, "boot partition: #{directory} already holds #{taken.join(', ')}" unless taken.empty?

      Dir.mktmpdir('.boot-partition-', directory) do |work|
        files = File.join(work, PARTITION)
        written = plan.to_h do |name, source|
          path = File.join(files, name)
          FileUtils.mkdir_p(File.dirname(path))
          bytes = source.is_a?(Text) ? source.bytes : BoundedFile.read(source, maximum: MAX_FILE)
          host = BuildPath.find_in(bytes, root: root)
          raise Error, "boot partition: #{name} holds the build's path #{host}" if host
          File.open(path, File::WRONLY | File::CREAT | File::EXCL, 0o644) { |file| file.write(bytes) }
          [name, Digest::SHA256.hexdigest(bytes)]
        end
        receipt = yield work, files, written
        File.write(File.join(work, record_name), JSON.pretty_generate(receipt) + "\n")
        entries.each { |name| File.rename(File.join(work, name), File.join(directory, name)) }
      end
      directory
    end

    # Writes the card at card xz-compressed (XZ_ARGUMENTS) to to, which the runner creates
    # owner-only or truncates. runner runs xz (Runner).
    def compress(card, to:, runner:)
      runner.run(XZ_ARGUMENTS, name: 'card-xz', deadline: XZ_DEADLINE, env: XZ_ENVIRONMENT, stdin: card, stdout: to)
    end

    # The card's receipt, in the shape of the image's own (ProductionImage's assembled
    # receipts): the card as its artifact (none for a set, whose image is nil), each file of the partition as a component by
    # its name and SHA-256, then pieces, the card's other inputs (the EROFS image and the
    # data volume) by their names beside the card, and record's inputs.
    def receipt(record, image:, files:, pieces:)
      { 'version' => 1, 'kind' => 'assembled',
        **(image ? { 'artifact' => { 'path' => IMAGE, 'sha256' => Digest::SHA256.file(image).hexdigest } } : {}),
        'components' => files.sort.map { |name, sha256| { 'path' => "#{PARTITION}/#{name}", 'sha256' => sha256 } } +
                        pieces.sort.map { |name, sha256| { 'path' => name, 'sha256' => sha256 } },
        **record }
    end

    # The partition's files a parsed receipt lists, each name to its SHA-256: the
    # components under PARTITION/, as receipt writes them. A name that is not one of the
    # layout's (NAME) is refused, so a reader that places the files by these names stays
    # inside the directory it places them in.
    def listed_files(receipt)
      files = receipt.fetch('components').filter_map do |component|
        component.fetch_values('path', 'sha256') => [String => path, String => sha256]
        [path.delete_prefix("#{PARTITION}/"), sha256] if path.start_with?("#{PARTITION}/")
      end.to_h
      odd = files.keys.reject { |name| NAME.match?(name) }
      raise Error, "the card's build record lists #{odd.first.dump}, which is no file name of the boot partition" unless odd.empty?

      files
    rescue KeyError, NoMatchingPatternError
      raise Error, "the card's build record holds no list of the boot partition's files"
    end

    # The build record of a layout: the erXos commit the card is of, in full, and whether
    # the tree differed from it (nil when the tree is no git checkout); the firmware's
    # deps.lock pins, BL31's own build record (Bl31.record) and its license's place in
    # TF-A's pinned tree, the board tree's pinned source, recipe, overlay sources and
    # tools (the preprocessor and dtc), and the card's tool and arguments. The bootable
    # file's record is bootable_record when one is given, as the header probe gives its
    # own (HeaderProbe), and otherwise the image's, in the same directory. Paths are
    # relative to root, and each host tool is named by its version line (tool_version),
    # not by the identity BL31's own record keys its rebuilds on.
    def record(root:, runner:, revision:, platform:, firmware:, compiler:, linker:, bootable_record: nil)
      board = BoardTree.board(platform)
      version = ->(program) { tool_version(program, runner: runner) }
      { 'source' => (revision && { 'commit' => revision.commit, 'dirty' => revision.dirty }),
        'producer' => source_reference(root, __FILE__),
        'inputs' => { 'platform' => platform.name, 'firmware' => firmware,
                      'bl31' => Bl31.record(root: root, compiler: compiler, linker: linker)
                                    .merge('compiler' => version.(compiler), 'linker' => version.(linker)),
                      'bl31_license' => { 'source' => Bl31::SOURCE_ID, 'path' => Bl31::LICENSE },
                      'board_tree' => { 'source' => BoardTree.source_record(root: root), 'board' => board.source,
                                        'recipe' => source_reference(root, BoardTree.recipe_path),
                                        'overlays' => board.overlays.transform_values { |path| source_reference(root, File.join(root, path)) },
                                        'compiler' => version.(compiler), 'dtc' => version.(BoardTree.dtc_path) },
                      'card' => { 'tool' => Fsimg::VERSION_LINE, 'source' => Fsimg.source_record(root: root),
                                   'arguments' => PiMedium.arguments },
                      'bootable' => bootable_record }.compact }
    end

    # An absolute path's mark in a record: a single slash that starts a string or follows
    # a space, an opening bracket, a quote or a separator (`--sysroot=/x`, `PATH:/x`), or
    # a triple slash (`file:///x`), or a home directory's `~/`. A URL's `://` is a double
    # slash, and a relative path's slashes follow a name.
    ABSOLUTE_PATH = %r{(?:\A|[\s(=:,'"\[])/(?!/)|///|~/}
    # What every string of a publishable record is: printable ASCII, as the pins, relative
    # paths, digests and version lines it is made of are, so it carries no control or
    # bidirectional character to a reader's terminal or browser.
    PRINTABLE = /\A[ -~]*\z/
    VERSION_BYTES = 4096
    VERSION_DEADLINE = 30

    # The first line program prints for --version (`Homebrew clang version 21.1.5`),
    # which names the tool without the path it was found at. A line that is empty or not
    # printable ASCII is refused; one that names a path is the website's to refuse
    # (check_record).
    def tool_version(program, runner:)
      log = runner.run([program, '--version'], name: 'boot-partition-tool-version', deadline: VERSION_DEADLINE).fetch('log')
      line = BoundedFile.read(log, maximum: VERSION_BYTES).lines.first.to_s.strip
      raise Error, "boot partition: #{File.basename(program)} --version gives no version line fit for the card's record" unless
        line.match?(/\A[ -~]+\z/)

      line
    end

    # The most of a place an error names, so a long key does not fill the log.
    PLACE_CHARACTERS = 200

    # receipt, once every string in it is printable ASCII and none names an absolute
    # path, which would carry the build host's directories, and a user's name with
    # them, to whoever the card is given to; the website checks a card's record with it
    # (Site.card_record). The error names where the string is, not the string, so the
    # website's build log does not publish it.
    def check_record(receipt)
      strings = record_strings(receipt)
      odd = strings.find { |_place, text| !PRINTABLE.match?(text) }
      raise Error, "the card's build record holds a string that is not printable ASCII in #{odd.first}" if odd

      found = strings.find { |_place, text| ABSOLUTE_PATH.match?(text) }
      raise Error, "the card's build record names an absolute path in #{found.first}" if found

      receipt
    end

    # Every key and string value of a parsed record, whose nesting its parser bounds
    # (JsonInput), each with its place: a value's keys and indices from the top, a key's
    # its parent's. Keys come before what they hold, so a key that is a path is found
    # before a place that would spell it.
    def record_strings(value, keys = [])
      place = keys.empty? ? 'the record' : keys.join('/').dump[0, PLACE_CHARACTERS]
      case value
      in Hash then value.flat_map { |key, item| [["a key of #{place}", key], *record_strings(item, [*keys, key])] }
      in Array then value.each_with_index.flat_map { |item, index| record_strings(item, [*keys, index]) }
      in String then [[place, value]]
      else []
      end
    end

    def source_reference(root, path)
      { 'path' => File.realpath(path).delete_prefix("#{File.realpath(root)}/"), 'sha256' => Digest::SHA256.file(path).hexdigest }
    end

    # Builds BL31 and the board's tree, takes the firmware as deps.lock pins it, verified
    # against its pinned hashes, formats the data partition's volume, and writes the
    # layout for bootable and erofs, the release's EROFS image or nil for an empty slot,
    # with its build record, into directory, the production image's or the header probe
    # card's. revision names the commit in the device tree's notice and the record, read
    # once so both name one; bootable_record is the bootable file's own (record).
    def lay_out(root:, runner:, platform:, build_kind:, bootable:, erofs:, directory:, compiler:, linker:,
                revision: SourceRevision.read(root: root, runner: runner), bootable_record: nil)
      plan, record = layout(root: root, runner: runner, platform: platform, build_kind: build_kind, bootable: bootable,
                            compiler: compiler, linker: linker, revision: revision, bootable_record: bootable_record)
      volume = DataVolume.format(root: root, runner: runner, compiler: compiler, directory: directory,
                                 data_sectors: MediumImage::PACKED_DATA_SECTORS)
      write(root: root, directory: directory, plan: plan, record: record, runner: runner,
            fsimg: Fsimg.checked(root: root, runner: runner), erofs: erofs, volume: volume)
    end

    # Lays the partition's files for bootable out into directory with their build record,
    # as lay_out does, without the card: a bench set (write_set). With boot_cpu_only, the
    # board's tree keeps only the boot CPU (BoardTree.boot_cpu_only), and the record says so.
    # The record states what config.txt sets that a run's record keeps (card_settings).
    def lay_out_set(root:, runner:, platform:, build_kind:, bootable:, directory:, compiler:, linker:,
                    revision: SourceRevision.read(root: root, runner: runner), boot_cpu_only: false)
      plan, record = layout(root: root, runner: runner, platform: platform, build_kind: build_kind, bootable: bootable,
                            compiler: compiler, linker: linker, revision: revision, bootable_record: nil,
                            boot_cpu_only: boot_cpu_only)
      # A set has no card, so its record names no card's tool.
      record = record.merge('inputs' => record.fetch('inputs').except('card'))
      record = record.merge('board_tree_cpus' => 'boot CPU only') if boot_cpu_only
      write_set(root: root, directory: directory, plan: plan, record: record.merge(card_settings(platform).to_record))
    end

    # What platform's config.txt sets that a board run's record keeps (CardSettings::Card),
    # from the values config_txt writes: the ARM clock, when the platform's record names
    # one, and total_mem.
    def card_settings(platform)
      CardSettings::Card.new(arm_clock_hz: CardSettings.clock_hz(platform.record, label: platform.record_path),
                             memory_mib: total_mem_mib(platform))
    end

    # The plan and the build record of bootable's partition on platform: BL31 and the
    # board's tree built, the firmware as deps.lock pins it, verified against its pinned
    # hashes.
    def layout(root:, runner:, platform:, build_kind:, bootable:, compiler:, linker:, revision:, bootable_record:,
               boot_cpu_only: false)
      dependencies = Dependencies.new(root: root, runner: runner)
      pinned = FIRMWARE.map { |id| dependencies.archive_for(id) }
      plan = plan(platform: platform, build_kind: build_kind, bootable: bootable,
                  firmware: pinned.to_h { |source, archive| [source.fetch('filename'), archive] },
                  bl31_license: Bl31.license(root: root, runner: runner),
                  bl31: Bl31.ensure(root: root, runner: runner, compiler: compiler, linker: linker),
                  tree: BoardTree.build(root: root, runner: runner, platform: platform, compiler: compiler, revision: revision)
                                 .then { |built| boot_cpu_only ? BoardTree.boot_cpu_only(built, runner: runner) : built })
      [plan, record(root: root, runner: runner, revision: revision, platform: platform,
                    firmware: pinned.map(&:first), compiler: compiler, linker: linker, bootable_record: bootable_record)]
    end
  end
end
