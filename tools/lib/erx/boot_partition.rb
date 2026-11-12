# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'fileutils'
require 'tmpdir'
require_relative 'error'
require_relative 'bl31'
require_relative 'board_tree'
require_relative 'bounded_file'
require_relative 'dependencies'
require_relative 'output_directory'
require_relative 'platform'

module Erx
  # The Raspberry Pi 4's boot files, laid out in one directory that serves both as the
  # firmware's network boot (TFTP) root and as an SD card's FAT boot partition
  # (docs/design-stopgap.md, "The Raspberry Pi 4"; docs/design-platforms.md, "Firmware"):
  # the firmware, unmodified, with its licence; config.txt, written from the platform
  # record; the board's device tree, unmodified, with its source, and the overlays
  # config.txt names; TF-A's BL31 as the armstub, with its licence; and the bootable
  # file as kernel8.img.
  #
  # Every name in the layout is one of this module's own, so nothing a caller passes
  # chooses where a file lands; the layout is written in a fresh directory beside the
  # output and renamed into place whole.
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

    module_function

    # config.txt for platform: a 64-bit kernel from kernel8.img with BL31 as its stub,
    # the mini UART's line pinned (enable_uart), the PL011s' clock from the record, and
    # the overlays the board's tree carries.
    def config_txt(platform, overlays:)
      <<~CONFIG + overlays.map { |name| "dtoverlay=#{name}\n" }.join
        # erXos boot partition for #{platform.name}, written by tools/lib/erx/boot_partition.rb.
        arm_64bit=1
        kernel=#{KERNEL}
        armstub=#{ARMSTUB}
        enable_uart=1
        init_uart_clock=#{pl011_clock(platform)}
      CONFIG
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
    def plan(platform:, bootable:, bl31:, bl31_licence:, tree:, firmware:)
      board = BoardTree.board(platform)
      own = { KERNEL => bootable, ARMSTUB => bl31, ARMSTUB_LICENCE => bl31_licence,
              CONFIG => Text.new(config_txt(platform, overlays: tree.overlays.keys)),
              board.file => tree.board, BoardTree.source_file(board) => tree.source,
              **tree.overlays.to_h { |name, path| ["overlays/#{name}.dtbo", path] } }
      clash = own.keys & firmware.keys
      raise Error, "boot partition: the firmware's #{clash.join(', ')} would replace a file of the layout" unless clash.empty?

      own.merge(firmware)
    end

    # Writes plan into output, which must lie under root, replacing what was there.
    def write(root:, output:, plan:)
      plan.each_key { |name| raise Error, "boot partition: #{name.inspect} is not a file name of the layout" unless NAME.match?(name) }
      output = File.expand_path(output)
      parent = OutputDirectory.prepare(root: root, path: File.dirname(output))
      destination = File.join(parent, File.basename(output))
      raise Error, "boot partition output is a symbolic link: #{destination}" if File.symlink?(destination)
      raise Error, "boot partition output #{destination} holds something other than a boot partition" unless replaceable?(destination)

      Dir.mktmpdir(".#{File.basename(output)}-", parent) do |work|
        layout = File.join(work, 'layout')
        Dir.mkdir(layout)
        plan.each do |name, source|
          path = File.join(layout, name)
          FileUtils.mkdir_p(File.dirname(path))
          bytes = source.is_a?(Text) ? source.bytes : BoundedFile.read(source, maximum: MAX_FILE)
          File.open(path, File::WRONLY | File::CREAT | File::EXCL, 0o644) { |file| file.write(bytes) }
        end
        FileUtils.rm_rf(destination)
        File.rename(layout, destination)
      end
      destination
    end

    # Whether destination may be replaced: absent, empty, or a layout this module wrote,
    # whose config.txt opens with its own first line.
    def replaceable?(destination)
      return true unless File.exist?(destination)
      return false unless File.directory?(destination)
      return true if Dir.empty?(destination)

      config = File.join(destination, CONFIG)
      File.file?(config) && !File.symlink?(config) &&
        BoundedFile.read(config, maximum: 4096).start_with?("# erXos boot partition for ")
    end

    # Builds BL31 and the board's tree, takes the firmware as deps.lock pins it, and
    # writes the layout for bootable into output.
    def lay_out(root:, runner:, platform:, bootable:, output:, compiler: ENV.fetch('ERX_CLANG', ''),
                linker: ENV.fetch('ERX_LLD', ''))
      dependencies = Dependencies.new(root: root, runner: runner)
      firmware = FIRMWARE.to_h do |id|
        source, archive = dependencies.archive_for(id)
        [source.fetch('filename'), archive]
      end
      plan = plan(platform: platform, bootable: bootable, firmware: firmware,
                  bl31_licence: Bl31.licence(root: root, runner: runner),
                  bl31: Bl31.ensure(root: root, runner: runner, compiler: compiler, linker: linker),
                  tree: BoardTree.build(root: root, runner: runner, platform: platform, compiler: compiler))
      write(root: root, output: output, plan: plan)
    end
  end
end
