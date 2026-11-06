# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'digest'
require 'tmpdir'
require_relative 'error'
require_relative 'runner'
require_relative 'bounded_file'
require_relative 'dependencies'
require_relative 'output_directory'

module Erx
  # The Linux guest that is the EROFS oracle (docs/design-storage.md, Reading EROFS
  # images): Debian's cloud kernel for arm64, whose EROFS driver mounts the images,
  # and an initramfs of Debian's static busybox with the guest's two scripts,
  # tools/linux_guest/init and describe. Both packages are pinned in deps.lock and
  # fetched by `tools/erx fetch`; this class takes from them only the files the guest
  # needs, after checking each package against its pinned SHA-256 again, and builds
  # the initramfs itself, so the guest is a function of the pins and the scripts.
  #
  # The guest runs under QEMU with no network device, every image attached read-only,
  # a deadline and its serial console in the run's log, and answers the manifest it
  # printed there (Erx::ErofsManifest), which the caller parses as untrusted input.
  class LinuxGuest
    KERNEL = 'linux-guest-kernel'
    USERLAND = 'linux-guest-busybox'
    RELEASE = '6.12.107+deb13-cloud-arm64'
    KERNEL_MEMBER = "./boot/vmlinuz-#{RELEASE}"
    # The modules the init script loads, in its order: EROFS needs libcrc32c, and the
    # disks are virtio-blk; busybox's insmod loads them xz-compressed, as Debian ships them.
    MODULES = { 'libcrc32c' => 'kernel/lib/libcrc32c.ko.xz',
                'virtio_blk' => 'kernel/drivers/block/virtio_blk.ko.xz',
                'erofs' => 'kernel/fs/erofs/erofs.ko.xz' }.freeze
    BUSYBOX_MEMBER = './usr/bin/busybox'
    SCRIPTS = %w[init describe].freeze
    MAX_MEMBER_BYTES = 128 * 1024 * 1024
    MAX_IMAGES = 64
    MAX_SERIAL_BYTES = 256 * 1024 * 1024
    ACCELERATORS = { 'hvf' => 'host', 'tcg' => 'max' }.freeze

    # The files QEMU boots: the kernel image and the initramfs.
    BootFiles = Data.define(:kernel, :initramfs)

    # The ar archive format of a Debian package: a magic line, then members, each a
    # 60-byte header with its name and decimal size, its bytes, and a pad to even.
    module Ar
      MAGIC = "!<arch>\n"
      HEADER = 60

      module_function

      # The bytes of the member called name, or Erx::Error.
      def member(bytes, name)
        bytes = bytes.b
        raise Error, 'Debian package is not an ar archive' unless bytes.start_with?(MAGIC)

        offset = MAGIC.bytesize
        while offset + HEADER <= bytes.bytesize
          header = bytes.byteslice(offset, HEADER)
          size = header.byteslice(48, 10).rstrip
          unless header.end_with?("`\n") && /\A[0-9]{1,10}\z/.match?(size) && offset + HEADER + size.to_i <= bytes.bytesize
            raise Error, 'Debian package has a malformed ar member'
          end

          start = offset + HEADER
          return bytes.byteslice(start, size.to_i) if header.byteslice(0, 16).rstrip.delete_suffix('/') == name

          offset = start + size.to_i + (size.to_i & 1)
        end
        raise Error, "Debian package has no #{name}"
      end
    end

    # The initramfs: a cpio archive in the kernel's "newc" format, every file owned by
    # root with time 0 and numbered in order, so the same files give the same bytes.
    module Cpio
      MAGIC = '070701'

      module_function

      # entries: [name, mode, bytes] in order, a directory's bytes nil.
      def archive(entries)
        records = entries.each_with_index.map do |(name, mode, bytes), index|
          record(name, mode: mode, data: bytes || '', ino: index + 1, links: bytes ? 1 : 2)
        end
        [*records, record('TRAILER!!!', mode: 0, data: '', ino: 0, links: 1)].join.b
      end

      def record(name, mode:, data:, ino:, links:)
        fields = [ino, mode, 0, 0, links, 0, data.bytesize, 0, 0, 0, 0, name.bytesize + 1, 0]
        pad("#{MAGIC}#{fields.map { |field| format('%08x', field) }.join}#{name}\0".b) + pad(data.b)
      end

      def pad(bytes) = bytes + ("\0" * (-bytes.bytesize % 4))
      private_class_method :record, :pad
    end

    def initialize(root:, runner:, qemu: 'qemu-system-aarch64', tar: 'tar')
      @root = root
      @runner = runner
      @qemu = qemu
      @tar = tar
    end

    # Builds the kernel and the initramfs into directory, which the caller owns. The
    # initramfs holds no /dev/console: the kernel's own built-in initramfs supplies it.
    def prepare(directory)
      kernel_files = extract(KERNEL, [KERNEL_MEMBER, *MODULES.values.map { |path| module_member(path) }], directory)
      busybox = extract(USERLAND, [BUSYBOX_MEMBER], directory).fetch(BUSYBOX_MEMBER)
      scripts = SCRIPTS.to_h { |name| [name, BoundedFile.read(File.join(@root, 'tools/linux_guest', name), maximum: 65_536)] }
      entries = [['bin', 0o40755, nil], ['bin/busybox', 0o100755, busybox], ['lib', 0o40755, nil],
                 ['lib/modules', 0o40755, nil],
                 *MODULES.map { |name, path| ["lib/modules/#{name}.ko.xz", 0o100644, kernel_files.fetch(module_member(path))] },
                 *SCRIPTS.map { |name| [name, 0o100755, scripts.fetch(name)] }]
      kernel = File.join(directory, 'vmlinuz')
      initramfs = File.join(directory, 'initramfs.cpio')
      File.binwrite(kernel, kernel_files.fetch(KERNEL_MEMBER))
      File.binwrite(initramfs, Cpio.archive(entries))
      BootFiles.new(kernel: kernel, initramfs: initramfs)
    end

    # Boots boot_files over images, in order, and answers the path of the log that holds
    # its serial console, at most MAX_SERIAL_BYTES.
    def run(boot_files, images:, accel: 'hvf', deadline: 600)
      record = @runner.run(self.class.argv(boot_files, images: images, accel: accel, qemu: @qemu),
                           name: 'erofs-oracle-guest', deadline: deadline, output_limit: MAX_SERIAL_BYTES)
      record.fetch('log')
    end

    # The QEMU command line: QEMU's virt machine with no default devices and no
    # network, image I (an absolute path) a read-only raw virtio disk with serial erx-image-I, the serial
    # console on standard output, and no reboot, so a guest that panics or powers off
    # ends QEMU.
    def self.argv(boot_files, images:, accel:, qemu: 'qemu-system-aarch64')
      cpu = ACCELERATORS.fetch(accel) { raise Error, "unknown accelerator: #{accel}" }
      raise Error, "the Linux guest takes 1 to #{MAX_IMAGES} images" unless images.size.between?(1, MAX_IMAGES)
      # QEMU reads a file= value with a colon before its first slash as a protocol.
      raise Error, 'the Linux guest takes images by absolute path' unless images.all? { |path| path.start_with?('/') }

      disks = images.each_with_index.flat_map do |path, index|
        ['-drive', "if=none,id=image#{index},format=raw,readonly=on,file=#{option(path)}",
         '-device', "virtio-blk-pci,drive=image#{index},serial=erx-image-#{index}"]
      end
      [qemu, '-M', 'virt', '-accel', accel, '-cpu', cpu, '-smp', '2', '-m', '1024',
       '-nodefaults', '-no-reboot', '-nic', 'none', '-display', 'none', '-monitor', 'none', '-serial', 'stdio',
       '-kernel', boot_files.kernel, '-initrd', boot_files.initramfs,
       '-append', "console=ttyAMA0 quiet loglevel=0 panic=-1 rdinit=/init erx.images=#{images.size}", *disks]
    end

    # A value inside a QEMU option list, where a comma is written twice.
    def self.option(value) = value.gsub(',', ',,')
    private_class_method :option

    private

    def module_member(path) = "./usr/lib/modules/#{RELEASE}/#{path}"

    # Answers the named members of the data archive of the pinned package id, read
    # into memory: each must be a regular file of at most MAX_MEMBER_BYTES.
    def extract(id, members, directory)
      package = pinned_package(id)
      Dir.mktmpdir("#{id}-", directory) do |work|
        data = File.join(work, 'data.tar.xz')
        File.binwrite(data, Ar.member(package, 'data.tar.xz'))
        tree = File.join(work, 'tree')
        Dir.mkdir(tree)
        @runner.run([@tar, '-xf', data, '-C', tree, *members], name: "linux-guest-#{id}", deadline: 300,
                                                                 output_limit: MAX_MEMBER_BYTES)
        members.to_h do |member|
          path = File.join(tree, member)
          unless File.lstat(path).file? && File.size(path) <= MAX_MEMBER_BYTES
            raise Error, "#{id}: #{member} is not a regular file of bounded size"
          end

          [member, File.binread(path)]
        end
      end
    end

    # The package of the deps.lock source id as fetched, after checking its SHA-256.
    def pinned_package(id)
      source = DependencySchema.parse(File.binread(File.join(@root, 'deps.lock'))).find { |entry| entry.fetch('id') == id }
      raise Error, "deps.lock pins no #{id}" unless source && source.fetch('kind') == 'file'

      path = File.join(@root, 'build/third_party', id, source.fetch('filename'))
      raise Error, "#{id} is not fetched; run tools/erx fetch --source #{id}" unless File.file?(path) && !File.symlink?(path)

      bytes = BoundedFile.read(path, maximum: Sources::MAX_ARCHIVE_BYTES)
      raise Error, "#{id} does not match its pinned SHA-256" unless Digest::SHA256.hexdigest(bytes) == source.fetch('sha256')

      bytes
    end
  end
end
