# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'digest'
require 'fileutils'
require 'json'
require 'tmpdir'
require_relative 'error'
require_relative 'fsimg'
require_relative 'bl31'
require_relative 'board_tree'
require_relative 'bounded_file'
require_relative 'build_memo'
require_relative 'build_path'
require_relative 'dependencies'
require_relative 'output_directory'
require_relative 'platform'
require_relative 'qemu'

module Erx
  # The Raspberry Pi 4's medium, the production image's for a board the firmware boots
  # (ProductionImage#build_medium): written beside the image, boot/ holds the boot
  # partition's files and serves as the firmware's network boot (TFTP) root; sdcard.img
  # is a disk image ready to write to a card, an MBR whose one partition, FAT32 (type
  # 0x0c), holds the same files; and sdcard.img.receipt.json is their build record
  # (docs/design-stopgap.md, "The Raspberry Pi 4"; docs/design-platforms.md, "Firmware").
  # The files are the firmware, unmodified, with its licence; config.txt, written from
  # the platform record; the board's device tree, unmodified, with its source, and the
  # overlays config.txt names; TF-A's BL31 as the armstub, with its licence; and the
  # production image's bootable file as kernel8.img.
  #
  # Every name in the layout is one of this module's own, so nothing a caller passes
  # chooses where a file lands. The three entries are written in a fresh work directory
  # inside the image's directory, then renamed beside the image; the image's directory
  # must not hold any of them already.
  module BootPartition
    KERNEL = 'kernel8.img'
    ARMSTUB = 'bl31.bin'
    CONFIG = 'config.txt'
    ARMSTUB_LICENCE = 'LICENCE.tf-a'
    # A file of the layout whose bytes are given, not read from a path.
    Text = Data.define(:bytes)
    # The firmware's files, by deps.lock pin; each keeps its pinned file name.
    FIRMWARE = %w[rpi-firmware-start4 rpi-firmware-fixup4 rpi-firmware-licence].freeze
    # A file name of the layout: one name, or one under overlays/.
    NAME = %r{\A(?:overlays/)?[A-Za-z0-9][A-Za-z0-9_.,+-]*\z}
    MAX_FILE = 64 * 1024 * 1024
    # The medium's three entries beside the image: the partition's files, the card's disk
    # image, and their build record.
    PARTITION = 'boot'
    IMAGE = 'sdcard.img'
    RECORD = 'sdcard.img.receipt.json'
    ENTRIES = [PARTITION, IMAGE, RECORD].freeze
    # The card's image, which fsimg writes and verifies: FAT32 in the one partition of an
    # MBR, type 0x0c (FAT32 with LBA), which the firmware boots from. 512 MiB with 4 KiB
    # clusters is the geometry of Raspberry Pi OS's own boot partition. The bytes are
    # reproducible, with every time at 1980-01-01, FAT's first representable date.
    CARD = %w[-F fat32/mbr -R -e 315532800 -s 512M -L ERXOS -o cluster=4096 -o mbr:type=0x0c].freeze
    CARD_DEADLINE = 300
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
    def plan(platform:, build_kind:, bootable:, bl31:, bl31_licence:, tree:, firmware:)
      board = BoardTree.board(platform)
      own = { KERNEL => bootable, ARMSTUB => bl31, ARMSTUB_LICENCE => bl31_licence,
              CONFIG => Text.new(config_txt(platform, overlays: tree.overlays.keys, build_kind: build_kind)),
              board.file => tree.board, BoardTree.source_file(board) => tree.source,
              **tree.overlays.to_h { |name, path| ["overlays/#{name}.dtbo", path] } }
      clash = own.keys & firmware.keys
      raise Error, "boot partition: the firmware's #{clash.join(', ')} would replace a file of the layout" unless clash.empty?

      own.merge(firmware)
    end

    # Writes plan into directory, an existing directory under root that holds none of
    # ENTRIES: the files under boot/, the card's image of them, written with fsimg and
    # verified, and record, the inputs' build record, with each file's and the card's
    # SHA-256 added.
    def write(root:, directory:, plan:, record:, runner:, fsimg:)
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
        image = File.join(work, IMAGE)
        runner.run([fsimg, 'cW', '-f', image, *CARD, '-C', files, '.'], name: 'fsimg-boot-partition', deadline: CARD_DEADLINE)
        File.write(File.join(work, RECORD), JSON.pretty_generate(receipt(record, image: image, files: written)) + "\n")
        ENTRIES.each { |name| File.rename(File.join(work, name), File.join(directory, name)) }
      end
      Written.new(path: File.join(directory, IMAGE), files: File.join(directory, PARTITION), record: File.join(directory, RECORD))
    end

    # The card's receipt, in the shape of the image's own (ProductionImage's assembled
    # receipts): the card as its artifact, each file of the partition as a component by
    # its name and SHA-256, and record's inputs. Pure.
    def receipt(record, image:, files:)
      { 'version' => 1, 'kind' => 'assembled',
        'artifact' => { 'path' => IMAGE, 'sha256' => Digest::SHA256.file(image).hexdigest },
        'components' => files.sort.map { |name, sha256| { 'path' => "#{PARTITION}/#{name}", 'sha256' => sha256 } },
        **record }
    end

    # The build record of a layout: the firmware's deps.lock pins, BL31's own build
    # record (Bl31.record) and its licence's place in TF-A's pinned tree, the board tree's
    # pinned source, recipe, overlay sources and tools (the preprocessor and dtc, by
    # identity), and the card's tool and arguments. The bootable file's record is the
    # image's, in the same directory. Paths are relative to root; a tool's identity is
    # its real path, digest and the host's release (BuildMemo.program_identity).
    def record(root:, platform:, firmware:, compiler:, linker:)
      board = BoardTree.board(platform)
      { 'producer' => source_reference(root, __FILE__),
        'inputs' => { 'platform' => platform.name, 'firmware' => firmware,
                      'bl31' => Bl31.record(root: root, compiler: compiler, linker: linker),
                      'bl31_licence' => { 'source' => Bl31::SOURCE_ID, 'path' => Bl31::LICENCE },
                      'board_tree' => { 'source' => BoardTree.source_record(root: root), 'board' => board.source,
                                        'recipe' => source_reference(root, BoardTree.recipe_path),
                                        'overlays' => board.overlays.transform_values { |path| source_reference(root, File.join(root, path)) },
                                        'compiler' => BuildMemo.program_identity(compiler),
                                        'dtc' => BuildMemo.program_identity(BoardTree.dtc_path) },
                      'card' => { 'tool' => Fsimg::VERSION_LINE, 'source' => Fsimg.source_record(root: root), 'arguments' => CARD } } }
    end

    def source_reference(root, path)
      { 'path' => File.realpath(path).delete_prefix("#{File.realpath(root)}/"), 'sha256' => Digest::SHA256.file(path).hexdigest }
    end

    # Builds BL31 and the board's tree, takes the firmware as deps.lock pins it, verified
    # against its pinned hashes, and writes the layout for bootable, with its build
    # record, into directory, the production image's.
    def lay_out(root:, runner:, platform:, build_kind:, bootable:, directory:, compiler:, linker:)
      dependencies = Dependencies.new(root: root, runner: runner)
      pinned = FIRMWARE.map { |id| dependencies.archive_for(id) }
      plan = plan(platform: platform, build_kind: build_kind, bootable: bootable,
                  firmware: pinned.to_h { |source, archive| [source.fetch('filename'), archive] },
                  bl31_licence: Bl31.licence(root: root, runner: runner),
                  bl31: Bl31.ensure(root: root, runner: runner, compiler: compiler, linker: linker),
                  tree: BoardTree.build(root: root, runner: runner, platform: platform, compiler: compiler))
      record = record(root: root, platform: platform, firmware: pinned.map(&:first), compiler: compiler, linker: linker)
      write(root: root, directory: directory, plan: plan, record: record, runner: runner,
            fsimg: Fsimg.checked(root: root, runner: runner))
    end
  end
end
