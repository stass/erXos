# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'fileutils'
require_relative 'bounded_file'
require_relative 'boot_image'
require_relative 'error'
require_relative 'native_boot'
require_relative 'native_root'
require_relative 'output_directory'
require_relative 'qemu'
require_relative 'qemu_cells'

module Erx
  # The boot image on QEMU end to end (docs/design-kernel.md, "Tests of the boot
  # image"): good images boot in both forms and the kernel reports the packer's
  # build identifier and index hash, and each damage a check claims to catch
  # stops the boot with that check's reason before the kernel prints a line.
  # Damage is written into a copy of the single file by offset, with a hash
  # recomputed where the damage must get past it.
  module BootImageCheck
    MEMORY_MIB = 512
    SERIAL_BYTES = 16 * 1024 * 1024
    KERNEL_LINE = /erXos\r?\n/n
    # The header's offsets are the format's, which a literal keeps independent
    # of the writer under test, as test/fixtures/pack_fixture.rb does.
    HEADER_VERSION = 8
    LOCATOR = 64
    # The large image's filler: with it the single file runs past the native root's
    # place, 64 MiB into RAM (NativeRoot::DEVELOPMENT_ROOT_MIB), and bootstrap says it
    # moves the archive before the kernel prints its banner.
    FILLER_PATH = 'boot/filler'
    FILLER_BYTES = 72 << 20
    MOVE_CHECKPOINT = { name: 'archive-move', pattern: /\AerXos image: moving the archive from 0x\h+ to 0x\h+\r?\n\z/n,
                        seconds: 60 }.freeze
    Case = Data.define(:name, :reason, :damage, :initrd, :strip_locator) do
      def self.of(name, reason, initrd: false, strip_locator: false, &damage)
        new(name: name, reason: reason, damage: damage, initrd: initrd, strip_locator: strip_locator)
      end
    end

    # What the kernel's line must report for this archive.
    def self.handoff_line(built)
      /\Aerx: boot image build #{built.build_id} index #{built.index_hash} flags 0x#{built.flags.to_s(16)} archive 0x[0-9a-f]+\+0x#{File.size(built.archive).to_s(16)} bootargs 0\r?\n\z/n
    end

    # The damage cases, in the order of the checks on the boot path. Each block
    # gets a Damage over the single file.
    CASES = [
      Case.of('locator magic', 'header: locator') { |image| image.flip(LOCATOR) },
      Case.of('locator version', 'header: locator') { |image| image.poke(LOCATOR + 8, [2].pack('V')) },
      Case.of('locator zero field', 'header: locator') { |image| image.poke(LOCATOR + 12, [1].pack('V')) },
      Case.of('archive inside the first stage', 'header: locator_range') { |image| image.poke(LOCATOR + 16, [0x1000].pack('Q<')) },
      Case.of('archive past the declared size', 'header: locator_range') { |image| image.poke(LOCATOR + 24, [image.archive_size + 4096].pack('Q<')) },
      Case.of('an initrd as well', 'header: two_boot_images', initrd: true) { |_image| nil },
      Case.of('no archive at all', 'header: no_boot_image', strip_locator: true) { |_image| nil },
      Case.of('a flipped entry byte', 'header: index_hash') { |image| image.flip_archive(96 + 4) },
      Case.of('a flipped string byte', 'header: index_hash') { |image| image.flip_archive(image.strings_off) },
      Case.of('a flipped index padding byte', 'header: index_hash') { |image| image.flip_archive(image.index_end) },
      Case.of('version 3 with its hash recomputed', 'header: version 3, expected 2') do |image|
        image.poke_archive(HEADER_VERSION, [3].pack('V'))
        image.rehash_index
      end,
      Case.of('the file cut into the kernel', 'boot/kernel: file_hash') { |image| image.cut_into('boot/kernel') },
      Case.of('a flipped kernel byte', 'boot/kernel: file_hash') { |image| image.flip_file('boot/kernel') },
      Case.of('a flipped sigma0 byte', 'boot/sigma0: file_hash') { |image| image.flip_file('boot/sigma0') },
      Case.of('kernel padding with its hash recomputed', 'boot/kernel: padding') do |image|
        image.pad_file('boot/kernel')
        image.rehash_file('boot/kernel')
        image.rehash_index
      end,
      Case.of('kernel entry not a file', 'boot/kernel: entry_not_file') do |image|
        image.kind('boot/kernel', 2)
        image.rehash_index
      end,
      Case.of('a kernel that is no ELF', 'boot/kernel: elf_header') do |image|
        image.flip_file('boot/kernel')
        image.rehash_file('boot/kernel')
        image.rehash_index
      end,
      Case.of('no kernel entry', 'boot/kernel: entry_missing') do |image|
        image.rename('boot/kernel', 'boot/kernek')
        image.rehash_index
      end
    ].freeze

    # A copy of the single file to damage, with the archive's layout read from
    # literal offsets.
    class Damage
      attr_reader :archive_off, :archive_size

      # digest gives the packer's BLAKE3 of a byte string, so a recomputed hash is
      # the packer's own.
      def initialize(bytes, digest:)
        @bytes = bytes.dup
        @digest = digest
        @archive_off = @bytes.byteslice(LOCATOR + 16, 8).unpack1('Q<')
        @archive_size = @bytes.byteslice(LOCATOR + 24, 8).unpack1('Q<')
      end

      def bytes = @bytes
      def strings_off = field(40, 8)
      def index_end = strings_off + field(48, 4)

      def poke(offset, value) = @bytes[offset, value.bytesize] = value
      def poke_archive(offset, value) = poke(@archive_off + offset, value)
      def flip(offset) = @bytes.setbyte(offset, @bytes.getbyte(offset) ^ 1)
      def flip_archive(offset) = flip(@archive_off + offset)
      # What a medium that lost the file's tail leaves: memory past it reads zero.
      def cut_into(path) = @bytes = @bytes.byteslice(0, @archive_off + field_of(path, 8, 8) + 16)
      def flip_file(path) = flip_archive(field_of(path, 8, 8))
      def kind(path, value) = poke_archive(entry_offset(path) + 6, [value].pack('C'))

      def rename(path, other)
        poke_archive(strings_off + field_of(path, 0, 4), other.b)
      end

      # A nonzero byte in the file's run after its data; every file the recipe
      # packs ends short of a page unless the build happens to fill it.
      def pad_file(path)
        finish = field_of(path, 8, 8) + field_of(path, 16, 8)
        raise Error, "#{path} has no padding to damage" if (finish % 4096).zero?

        flip_archive(finish)
      end

      def rehash_index
        finish = (index_end + 4095) / 4096 * 4096
        poke_archive(64, "\0".b * 32)
        poke_archive(64, @digest.call(@bytes.byteslice(@archive_off, finish)))
      end

      def rehash_file(path)
        start = field_of(path, 8, 8)
        finish = (start + field_of(path, 16, 8) + 4095) / 4096 * 4096
        poke_archive(entry_offset(path) + 32, @digest.call(@bytes.byteslice(@archive_off + start, finish - start)))
      end

      private

      def field(offset, width)
        @bytes.byteslice(@archive_off + offset, width).unpack1({ 2 => 'v', 4 => 'V', 8 => 'Q<' }.fetch(width))
      end

      def field_of(path, offset, width) = field(entry_offset(path) + offset, width)

      def entry_offset(path)
        (0...field(24, 4)).map { |index| 96 + index * 64 }.find do |entry|
          name = @bytes.byteslice(@archive_off + strings_off + field(entry, 4), field(entry + 4, 2))
          name == path.b
        end || raise(Error, "no entry #{path} in the image")
      end
    end

    class Run
      def initialize(root:, runner:, compiler:, linker:, platform: Platform.development(root))
        @root = File.expand_path(root)
        @platform = platform
        @runner = runner
        @compiler = compiler
        @linker = linker
        @build = File.join(@root, 'build/boot-image')
        @fiasco = Fiasco.new(root: @root, runner: runner, compiler: compiler)
      end

      # Every accelerator and CPU count on the good images, each form; the damage
      # cases on the first accelerator alone, since they stop before the second
      # CPU starts and their code is the same under both. Any disagreement raises.
      def call(accels:, cpus: [1, 4], jobs: 4, build: true, placement: QemuCells::HERE)
        @fiasco.build(jobs: jobs) if build
        recipe = BootImage.new(root: @root, runner: @runner, compiler: @compiler, linker: @linker)
        built = recipe.build(directory: File.join(@build, 'banner'))
        @digest = recipe.method(:digest)
        good = placement.each(accels: accels, cpus: cpus) do |accel, count, remote|
          ["#{accel}-#{count}cpu-single", boot(accel, count, built.single, built, remote: remote)]
        end
        two_file = accels.to_h { |accel| ["#{accel}-1cpu-two-file", boot(accel, 1, built.first_stage, built, initrd: built.archive)] }
        large = large_image(recipe)
        moved = accels.to_h { |accel| ["#{accel}-1cpu-moved", boot_moved(accel, large)] }
        { good: good.merge(two_file, moved), refused: refused(accels.first, built) }.freeze
      end

      private

      # A single file past the native root's place, 64 MiB into RAM, so bootstrap moves the
      # archive behind the root (docs/design-stopgap.md, "Boot handoff"); the root then
      # reads the archive at its new place and reports its index, as in the native boot.
      # It reuses the banner image's recipe: a second recipe would rebuild the pack tools
      # under the first one's helpers, whose checked inputs then no longer match.
      def large_image(recipe)
        FileUtils.mkdir_p(@build)
        filler = File.join(@build, 'filler')
        File.open(filler, 'wb') { |file| file.truncate(FILLER_BYTES) }
        root_task = NativeRoot.new(root: @root, runner: @runner, compiler: @compiler, linker: @linker, platform: @platform)
                              .build_no_program(directory: File.join(@build, 'large-root'))
        recipe.build(directory: File.join(@build, 'large'), stand_in_root: root_task, programs: { FILLER_PATH => filler })
      end

      def boot_moved(accel, built)
        # The file starts past RAM's first address, so one longer than the root's offset reaches it.
        size = File.size(built.single)
        if size <= NativeRoot::DEVELOPMENT_ROOT_MIB << 20
          raise Error, "the large image is #{size} bytes, short of the root's place, so its archive would not move"
        end

        points = NativeBoot.checkpoints(built).dup.insert(1, MOVE_CHECKPOINT)
        report = Qemu.new(root: @root, runner: @runner).run(platform: @platform, accel: accel, image: built.single, memory_mib: MEMORY_MIB,
                                                            checkpoints: points, machine_end: true)
        { serial: report.fetch('serial_log'), seconds: report.fetch('elapsed_seconds'),
          checkpoints: report.fetch('checkpoints') }.freeze
      end

      def boot(accel, count, image, built, initrd: nil, remote: nil)
        line = BootImageCheck.handoff_line(built)
        handoff = { name: 'handoff', pattern: /\Aerx: boot image build /n, seconds: 30,
                    verify: ->(text) { raise Error, "the kernel reports #{text.inspect}, not this image" unless line.match?(text) } }.freeze
        ordered = [*Qemu.boot_transcript(memory_mib: MEMORY_MIB), handoff]
        # No host link, so the kernel command line is empty and the handoff line says bootargs 0.
        report = Qemu.new(root: @root, runner: @runner).run(platform: @platform, accel: accel, cpus: count, remote: remote, image: image, initrd: initrd,
                                                            memory_mib: MEMORY_MIB, checkpoints: ordered,
                                                            hostlink: QemuPlan::NO_HOSTLINK)
        { serial: report.fetch('serial_log'), seconds: report.fetch('elapsed_seconds'),
          checkpoints: report.fetch('checkpoints') }.freeze
      end

      def refused(accel, built)
        directory = File.join(@build, 'damaged')
        OutputDirectory.prepare(root: @root, path: directory)
        single = BoundedFile.read(built.single, maximum: BootFile::FIRST_STAGE_MAX)
        CASES.to_h do |item|
          image = Damage.new(single, digest: @digest)
          item.damage.call(image)
          path = File.join(directory, item.name.tr(' ', '-'))
          File.binwrite(path, item.strip_locator ? BoundedFile.read(built.first_stage, maximum: BootFile::FIRST_STAGE_MAX) : image.bytes)
          [item.name, stop(accel, path, item, initrd: item.initrd ? built.archive : nil)]
        end
      end

      def stop(accel, path, item, initrd:)
        expected = "erXos image: #{item.reason}"
        points = [{ name: 'refusal', pattern: /\A#{Regexp.escape(expected)}\r?\n\z/n, seconds: 30 }.freeze]
        report = begin
          Qemu.new(root: @root, runner: @runner).run(platform: @platform, accel: accel, image: path, initrd: initrd, memory_mib: MEMORY_MIB,
                                                     checkpoints: points)
        rescue Error => error
          raise Error, "boot image check: #{item.name}: no #{expected.inspect}: #{error.message}"
        end
        serial = BoundedFile.read(report.fetch('serial_log'), maximum: SERIAL_BYTES)
        raise Error, "boot image check: #{item.name} reached the kernel" if KERNEL_LINE.match?(serial)

        report.fetch('serial_log')
      end
    end
  end
end
