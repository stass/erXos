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
require_relative 'board_tree'
require_relative 'bounded_file'
require_relative 'build_path'
require_relative 'dependencies'
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
  # them, and whose data partition holds a fresh littlefs volume; and
  # sdcard.img.receipt.json is their build record
  # (docs/design-stopgap.md, "The Raspberry Pi 4"; docs/design-platforms.md, "Firmware").
  # The files are the firmware, unmodified, with its license; config.txt, written from
  # the platform record; the board's device tree, with its one marked edit, its source
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
    ARMSTUB_LICENSE = 'LICENSE.tf-a'
    # A file of the layout whose bytes are given, not read from a path.
    Text = Data.define(:bytes)
    # The firmware's files, by deps.lock pin; each keeps its pinned file name.
    FIRMWARE = %w[rpi-firmware-start4 rpi-firmware-fixup4 rpi-firmware-license].freeze
    # A file name of the layout: one name, or one under overlays/.
    NAME = %r{\A(?:overlays/)?[A-Za-z0-9][A-Za-z0-9_.,+-]*\z}
    MAX_FILE = 64 * 1024 * 1024
    # The medium's three entries beside the image: the partition's files, the card's disk
    # image, and their build record.
    PARTITION = 'boot'
    IMAGE = 'sdcard.img'
    RECORD = 'sdcard.img.receipt.json'
    ENTRIES = [PARTITION, IMAGE, RECORD].freeze
    # The memory the firmware reports: total_mem makes any Pi 4 report the smallest
    # board's 1 GB, of which gpu_mem goes to the VideoCore, so the ARM's RAM is the same
    # on every board and on QEMU's 1 GB model, where the record's ram_bytes and
    # fiasco_reserve were measured. A larger board runs on that 1 GB.
    TOTAL_MEM_MIB = 1024
    GPU_MEM_MIB = 76
    # The pins of each overlay config.txt names. An overlay edits only the device tree,
    # and the firmware sets pins only from config.txt, so each overlay's pins follow it as
    # gpio lines: UART3 is GPIO 4 (TXD3) and GPIO 5 (RXD3) in function ALT4 (BCM2711 ARM
    # Peripherals, 5.3 "Alternative Function Assignments"), the receive line pulled up as
    # Linux's uart3_gpio4 pin group pulls it.
    OVERLAY_PINS = { 'uart3' => %w[gpio=4=a4,pn gpio=5=a4,pu] }.freeze

    # What write left in the image's directory: path, the card's image (the medium, as
    # ReleaseMedium::Written#path is QEMU's); files, the partition's directory; record,
    # their build record.
    Written = Data.define(:path, :files, :record)

    module_function

    # Whether platform's medium is a boot partition: a board whose firmware boots the
    # image from one, which is a board with a tree of its own (BoardTree::BOARDS).
    def boot_partition_medium?(platform) = BoardTree::BOARDS.key?(platform.name)

    # config.txt for platform and build_kind (development or release), setting by setting:
    # * arm_64bit, kernel, kernel_address, armstub: a 64-bit kernel8.img, loaded where the
    #   model's loader puts it and bootstrap is linked, entered through BL31.
    # * enable_uart: the console, the mini UART, on GPIO 14 and 15 in function ALT5, with
    #   its line set and the core clock it divides from pinned, so its divisor holds for
    #   the later stages. The firmware puts the pins in ALT5 whatever gpio= lines say.
    # * init_uart_clock: the PL011s' clock from the record, for UART3, the host link.
    # * total_mem, gpu_mem: the record's RAM.
    # * development_lines: the firmware's own boot log on the console and the JTAG pins,
    #   on a development card only.
    # * each overlay the board's tree carries, with its pins.
    def config_txt(platform, overlays:, build_kind:)
      <<~CONFIG + development_lines(build_kind) + overlays.map { |name| overlay_lines(name) }.join
        # erXos boot partition for #{platform.name}, written by tools/lib/erx/boot_partition.rb.
        arm_64bit=1
        kernel=#{KERNEL}
        kernel_address=0x#{QemuPlan::MACHINES.fetch(platform.name).loads.image.to_s(16)}
        armstub=#{ARMSTUB}
        enable_uart=1
        init_uart_clock=#{pl011_clock(platform)}
        total_mem=#{total_mem_mib(platform)}
        gpu_mem=#{GPU_MEM_MIB}
      CONFIG
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

    # The firmware's own boot log on the console (uart_2ndstage), and the ARM's JTAG on
    # GPIO 22 to 27 in function ALT4 (enable_jtag_gpio), for a probe when the serial log
    # cannot locate a hang, on pins neither the console (GPIO 14 and 15) nor UART3 (GPIO 4
    # and 5) uses. A release card keeps both off its header.
    def development_lines(build_kind)
      case build_kind
      in 'development' then "uart_2ndstage=1\nenable_jtag_gpio=1\n"
      in 'release' then ''
      else raise Error, "boot partition: build kind #{build_kind.inspect} is neither development nor release"
      end
    end

    def overlay_lines(name)
      pins = OVERLAY_PINS.fetch(name) { raise Error, "boot partition: the pins of overlay #{name} are not known" }
      ["dtoverlay=#{name}", *pins].map { |line| "#{line}\n" }.join
    end

    # The one clock of the record's PL011s, which config.txt's init_uart_clock sets for
    # all of them. A record whose PL011s disagree, or that has none, is refused.
    def pl011_clock(platform)
      clocks = platform.record.fetch('units').flat_map { |unit| unit.fetch('devices') }
                       .select { |device| device['compatible'] == 'arm,pl011' }.map { |device| device['clock'] }.uniq
      raise Error, "#{platform.record_path}: the PL011s need one clock, not #{clocks.inspect}" unless
        clocks.size == 1 && clocks[0].is_a?(Integer) && clocks[0].positive?

      clocks[0]
    end

    # The layout as a map from each file's name in the partition to its source path,
    # or to its Text for config.txt; firmware maps each firmware file's name to its path.
    # Pure.
    def plan(platform:, build_kind:, bootable:, bl31:, bl31_license:, tree:, firmware:)
      board = BoardTree.board(platform)
      own = { KERNEL => bootable, ARMSTUB => bl31, ARMSTUB_LICENSE => bl31_license,
              CONFIG => Text.new(config_txt(platform, overlays: tree.overlays.keys, build_kind: build_kind)),
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
    # boot ROM reads, followed by erofs, the release's EROFS image, and whose data
    # partition holds volume, a fresh littlefs volume of PiMedium.data_sectors sectors
    # (DataVolume.format); and record, the inputs' build record, with the SHA-256 of
    # each file, the EROFS image, the volume and the card added.
    def write(root:, directory:, plan:, record:, runner:, fsimg:, erofs:, volume:)
      plan.each_key { |name| raise Error, "boot partition: #{name.inspect} is not a file name of the layout" unless NAME.match?(name) }
      directory = OutputDirectory.check(root: root, path: directory)
      raise Error, "boot partition: #{directory} is not a directory" unless File.directory?(directory)

      taken = ENTRIES.select { |name| File.exist?(File.join(directory, name)) || File.symlink?(File.join(directory, name)) }
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
        image = PiMedium.write(directory: work, name: IMAGE, files: files, names: plan.keys.map { |name| name.split('/').first }.uniq,
                               erofs: erofs, volume: volume, runner: runner, fsimg: fsimg)
        pieces = { File.basename(erofs) => Digest::SHA256.file(erofs).hexdigest,
                   File.basename(volume.path) => Digest::SHA256.file(volume.path).hexdigest }
        File.write(File.join(work, RECORD), JSON.pretty_generate(receipt(record, image: image, files: written, pieces: pieces)) + "\n")
        ENTRIES.each { |name| File.rename(File.join(work, name), File.join(directory, name)) }
      end
      Written.new(path: File.join(directory, IMAGE), files: File.join(directory, PARTITION), record: File.join(directory, RECORD))
    end

    # The card's receipt, in the shape of the image's own (ProductionImage's assembled
    # receipts): the card as its artifact, each file of the partition as a component by
    # its name and SHA-256, then pieces, the card's other inputs (the EROFS image and the
    # data volume) by their names beside the card, and record's inputs.
    def receipt(record, image:, files:, pieces:)
      { 'version' => 1, 'kind' => 'assembled',
        'artifact' => { 'path' => IMAGE, 'sha256' => Digest::SHA256.file(image).hexdigest },
        'components' => files.sort.map { |name, sha256| { 'path' => "#{PARTITION}/#{name}", 'sha256' => sha256 } } +
                        pieces.sort.map { |name, sha256| { 'path' => name, 'sha256' => sha256 } },
        **record }
    end

    # The build record of a layout: the erXos commit the card is of, in full, and whether
    # the tree differed from it (nil when the tree is no git checkout); the firmware's
    # deps.lock pins, BL31's own build record (Bl31.record) and its license's place in
    # TF-A's pinned tree, the board tree's pinned source, recipe, overlay sources and
    # tools (the preprocessor and dtc), and the card's tool and arguments. The bootable
    # file's record is the image's, in the same directory. Paths are relative to root,
    # and each host tool is named by its version line (tool_version), not by the
    # identity BL31's own record keys its rebuilds on.
    def record(root:, runner:, revision:, platform:, firmware:, compiler:, linker:)
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
                                   'arguments' => PiMedium.arguments } } }
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
    # layout for bootable and erofs, the release's EROFS image, with its build record,
    # into directory, the production image's.
    def lay_out(root:, runner:, platform:, build_kind:, bootable:, erofs:, directory:, compiler:, linker:)
      dependencies = Dependencies.new(root: root, runner: runner)
      pinned = FIRMWARE.map { |id| dependencies.archive_for(id) }
      # Read once, so the device tree's notice and the card's record name one revision.
      revision = SourceRevision.read(root: root, runner: runner)
      plan = plan(platform: platform, build_kind: build_kind, bootable: bootable,
                  firmware: pinned.to_h { |source, archive| [source.fetch('filename'), archive] },
                  bl31_license: Bl31.license(root: root, runner: runner),
                  bl31: Bl31.ensure(root: root, runner: runner, compiler: compiler, linker: linker),
                  tree: BoardTree.build(root: root, runner: runner, platform: platform, compiler: compiler,
                                        revision: revision))
      record = record(root: root, runner: runner, revision: revision, platform: platform,
                      firmware: pinned.map(&:first), compiler: compiler, linker: linker)
      volume = DataVolume.format(root: root, runner: runner, compiler: compiler, directory: directory,
                                 data_sectors: PiMedium.data_sectors)
      write(root: root, directory: directory, plan: plan, record: record, runner: runner,
            fsimg: Fsimg.checked(root: root, runner: runner), erofs: erofs, volume: volume)
    end
  end
end
