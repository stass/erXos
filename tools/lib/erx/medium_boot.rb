# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'digest/md5'
require 'fileutils'
require_relative 'boot_record'
require_relative 'error'
require_relative 'fiasco'
require_relative 'output_directory'
require_relative 'production_image'
require_relative 'qemu'
require_relative 'release_medium'
require_relative 'runner'

module Erx
  # The QEMU harness as the firmware of a release medium (docs/design-platforms.md,
  # "Slots and the boot-selection record"): it reads the boot-selection record with the
  # slot parser (BootRecord), copies the committed slot's bootable file out of the
  # medium, boots it with -kernel and the medium as the guest's block device, and
  # writes the boot value into /chosen/bootloader of QEMU's own device tree, which it
  # passes with -dtb. Every boot here is a normal boot: the harness asks for no trial,
  # so tryboot is 0.
  module MediumBoot
    # The kernel's line that names the boot value it took from /chosen.
    BOOT_VALUE = /\Aerx: boot value /n

    # An expression for a shell of the booted system that runs the CRC-32C per-byte
    # primitive, erx_bytes:crc32c/2: over "123456789", whose CRC-32C is RFC 3720's check
    # value E3069283; over 100000 bytes in two calls, the second continuing the first,
    # since one call takes at most 65536 bytes; and over those 100000 bytes in one call,
    # which is refused. It follows another typed expression, whose variables stay bound in
    # the shell, and a shell fun sees them, so it names values only as fun parameters,
    # which shadow them. It starts with a fun, so the shell's echo of it does not start
    # {crc32c, and only the answer matches CRC32C_START.
    CRC32C_EXPRESSION = '(fun(Data)->(fun(Head,Tail)->' \
                        '{crc32c,integer_to_list(erx_bytes:crc32c(0,<<"123456789">>),16),' \
                        'integer_to_list(erx_bytes:crc32c(erx_bytes:crc32c(0,Head),Tail),16),' \
                        'try erx_bytes:crc32c(0,Data) catch error:badarg->badarg end} end)' \
                        '(binary:part(Data,0,65536),binary:part(Data,65536,byte_size(Data)-65536)) end)' \
                        '(binary:copy(<<"erXos">>,20000)).'
    # 2D78517F is the CRC-32C of 20000 copies of "erXos", from the bitwise model in
    # test/host/medium_boot_test.rb.
    CRC32C_ANSWER = '{crc32c,"E3069283","2D78517F",badarg}'
    CRC32C_START = /\A(?:[0-9]+> )?\{crc32c,/n

    module_function

    # The device tree source that adds the firmware's two properties to a tree: dtc
    # merges a node defined twice, so appended to QEMU's own tree it adds them under its
    # /chosen. choice is the slot parser's answer.
    def chosen_source(choice)
      partition = BootRecord::SLOTS.fetch(choice.slot).partition
      "\n/ {\n\tchosen {\n\t\tbootloader {\n\t\t\tpartition = <#{partition}>;\n\t\t\ttryboot = <0>;\n\t\t};\n\t};\n};\n"
    end

    # The checkpoint of the kernel's boot value line: a normal boot of the chosen slot.
    def boot_value_checkpoint(choice)
      whole = /\Aerx: boot value normal slot #{choice.slot}\r?\n\z/n
      { name: 'boot-value', pattern: BOOT_VALUE, seconds: 30,
        verify: ->(text) { raise Error, "the kernel reports #{text.inspect}" unless whole.match?(text) } }.freeze
    end

    # The production boot's checkpoints with the boot value's inserted: the kernel
    # prints "erx: boot image build ..." and then "erx: boot value ...". At the shell the
    # person reads a release file from the slot's EROFS image (image_checkpoints), and
    # then runs the CRC-32C primitive (CRC32C_EXPRESSION).
    def checkpoints(points, choice, release:)
      at = points.index { |point| point.fetch(:name) == 'image-identity' }
      raise Error, 'the production checkpoints name no image-identity' unless at
      raise Error, 'the production checkpoints do not end at the shell' unless points.last.fetch(:name) == 'release-shell'

      shell, image_answer = image_checkpoints(points.last, release)
      [*points[0..at], boot_value_checkpoint(choice), *points[(at + 1)...-1], shell,
       *crc32c_checkpoints(image_answer)].freeze
    end

    # After the shell's line previous, the person types CRC32C_EXPRESSION, and its answer
    # must be CRC32C_ANSWER whole.
    def crc32c_checkpoints(previous)
      whole = /\A(?:[0-9]+> )?#{Regexp.escape(CRC32C_ANSWER)}\r*\n\z/n
      [previous.merge(type: "#{CRC32C_EXPRESSION}\r").freeze,
       { name: 'crc32c', pattern: CRC32C_START, seconds: 30,
         verify: ->(text) { raise Error, "the shell answered #{text.inspect} to the CRC-32C expression" unless whole.match?(text) } }.freeze]
    end

    # The release file the shell reads from the image: stdlib's lists module, many blocks long.
    IMAGE_FILE = %r{\Asystem/lib/stdlib-[^/]+/ebin/lists\.beam\z}

    # At the shell's banner, the person types an expression that waits for the block driver
    # to have started, which is when its image mounts are made, and prints the MD5 of
    # IMAGE_FILE as /images/release shows it, the system release's EROFS image in the slot
    # (docs/design-stopgap.md, "Image windows"); it must be the MD5 of the file the
    # packer put in the image. The echo of the line does not start {image_md5, so only
    # the answer matches.
    def image_checkpoints(shell, release)
      entry = release.find { |candidate| IMAGE_FILE.match?(candidate.fetch('path')) }
      raise Error, 'the release has no stdlib lists module to read from the image' unless entry

      path = "/images/release/#{entry.fetch('path')}"
      digest = Digest::MD5.file(entry.fetch('artifact')).hexdigest.upcase
      expression = "application:ensure_all_started(erx_blk),case file:read_file(\"#{path}\") of " \
                   "{ok,B}->{image_md5,binary:encode_hex(erlang:md5(B))};E->{image_md5,E} end.\r"
      whole = /\A(?:[0-9]+> )?\{image_md5,<<"#{digest}">>\}\r*\n\z/n
      [shell.merge(type: expression).freeze,
       { name: 'image-md5', pattern: /\A(?:[0-9]+> )?\{image_md5,/n, seconds: 120,
         verify: ->(text) { raise Error, "the shell read #{text.inspect} from the image" unless whole.match?(text) } }.freeze]
    end

    # Boots the production image from its release medium to the shell under HVF.
    class Run
      MEMORY_MIB = ProductionImage::MEMORY_MIB
      # Under HVF the watchdog numbers are the kernel's defaults, whatever they are.
      WATCHDOG = '[0-9]+,[0-9]+,[0-9]+'

      def initialize(root:, runner: Runner.new(owner_root: root, log_dir: File.join(root, 'build/logs')),
                     compiler: ENV.fetch('ERX_CLANG', ''), linker: ENV.fetch('ERX_LLD', ''), qemu: 'qemu-system-aarch64')
        @root = File.expand_path(root)
        @runner = runner
        @compiler = compiler
        @linker = linker
        @qemu = qemu
      end

      # Packs the production image and its release medium once, then boots each CPU
      # count from a fresh copy of the medium. Returns { "hvf-<n>cpu" => 'passed' }; any
      # disagreement raises.
      def call(cpus:, jobs: 4, build: true)
        fiasco = Fiasco.new(root: @root, runner: @runner, compiler: @compiler)
        fiasco.build(jobs: jobs) if build
        directory = ProductionImage.clear_directory(root: @root, path: File.join(@root, 'build/medium-boot/image'))
        built, written = ProductionImage.new(root: @root, runner: @runner, compiler: @compiler, linker: @linker, fiasco: fiasco)
                                        .build_medium(directory: directory)
        cpus.to_h { |count| ["hvf-#{count}cpu", boot(count, built, written)] }
      end

      private

      def boot(count, built, written)
        directory = OutputDirectory.prepare(root: @root, mode: 0o700,
                                            path: File.join(@root, 'build/medium-boot', "hvf-#{count}cpu-#{Process.pid}-#{Random.bytes(8).unpack1('H*')}"))
        medium = ReleaseMedium.medium(written.slot, directory: directory, data_sectors: written.data_sectors)
        choice = BootRecord.read(medium)
        image = BootRecord.extract(medium, choice, output: File.join(directory, 'slot.boot'))
        raise Error, 'the slot parser chose a file that is not the packed image' unless FileUtils.compare_file(image, built.single)

        disks = [QemuPlan::Disk.new(path: medium)]
        points = ProductionImage::Run.checkpoints(built, root: @root, watchdog: WATCHDOG, cpus: count)
        Qemu.new(root: @root, runner: @runner, program: @qemu)
            .run(accel: 'hvf', cpus: count, image: image, memory_mib: MEMORY_MIB, directory: File.join(directory, 'boot'),
                 checkpoints: MediumBoot.checkpoints(points, choice, release: built.release), dtb: firmware_tree(count, image, disks, choice, directory),
                 disks: disks)
        'passed'
      end

      # QEMU's own tree for this boot's machine with the firmware's /chosen properties.
      def firmware_tree(count, image, disks, choice, directory)
        stock = File.join(directory, 'virt.dtb')
        tree = File.join(directory, 'firmware.dtb')
        source = File.join(directory, 'firmware.dts')
        argv = QemuPlan.argv(accel: 'hvf', image: image, serial: '/dev/null', cpus: count, memory_mib: MEMORY_MIB,
                             program: @qemu, disks: disks)
        machine = argv.index('-machine') + 1
        @runner.run([*argv[0...machine], "#{argv[machine]},dumpdtb=#{stock}", *argv[(machine + 1)..]],
                    name: 'qemu-dumpdtb-firmware', deadline: 30)
        listing = File.read(@runner.run(['dtc', '-q', '-I', 'dtb', '-O', 'dts', stock], name: 'dtc-firmware', deadline: 30).fetch('log'))
        File.write(source, listing + MediumBoot.chosen_source(choice))
        @runner.run(['dtc', '-q', '-I', 'dts', '-O', 'dtb', '-o', tree, source], name: 'dtc-firmware-tree', deadline: 30)
        tree
      end
    end
  end
end
