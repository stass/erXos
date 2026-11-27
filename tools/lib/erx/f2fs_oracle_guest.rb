# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'base64'
require 'digest'
require 'fileutils'
require_relative 'error'
require_relative 'line_escape'
require_relative 'output_directory'
require_relative 'platform'
require_relative 'qemu'
require_relative 'side_lock'

module Erx
  # The F2FS oracle guest (docs/design-f2fs.md, "The Linux oracle guest"): Ubuntu's arm64
  # cloud image as the root disk, booted by its own kernel and initrd under HVF, through
  # QEMU's own UEFI firmware since the kernel is an EFI application, the disk a
  # snapshot QEMU discards at exit, so every batch starts from the pinned image, with no
  # network device. Its one other disk, read-only, is the batch: the script
  # test/f2fs/oracle_guest.sh with its calls appended, f2fs-tools' package and the images,
  # each at a MiB-aligned offset. Per image the guest runs `fsck.f2fs -f --dry-run`,
  # answering no to every question, an `ro,norecovery` mount and a record of the
  # mounted tree, and prints each step's output, its size and SHA-256 and its status on
  # the serial console; per probe it first formats a blank image with Linux's own
  # `mkfs.f2fs` and prints the image too. Judge and listing here decide what the lines
  # mean. A batch holds images of one origin, so a hostile image that ends the guest
  # never takes erXos's verdicts with it. Linux and f2fs-tools are GPL and run
  # only as black boxes in the guest. Its pins are its own lock, test/f2fs/deps.lock,
  # fetched on demand (`tools/erx fetch --f2fs-oracle`).
  module F2fsOracleGuest
    LABEL = 'f2fs-oracle'
    LOCK = 'test/f2fs/deps.lock'
    WORKSPACE = 'build/f2fs-oracle-sources'
    ROOT_DISK = 'ubuntu-cloudimg-arm64'
    KERNEL = 'ubuntu-cloudimg-arm64-vmlinuz'
    INITRD = 'ubuntu-cloudimg-arm64-initrd'
    TOOLS = 'ubuntu-f2fs-tools'
    SCRIPT = 'test/f2fs/oracle_guest.sh'
    BATCH_SERIAL = 'erxbatch'
    # The image's root file system by its label; cloud-init off, since no datasource is
    # attached; no status lines from systemd and no login prompt on the console, which
    # would break the batch's lines; the batch run as systemd's one transient service, the
    # machine powered off whatever its end.
    COMMAND_LINE = ['root=LABEL=cloudimg-rootfs', 'ro', 'console=ttyAMA0', 'panic=-1', 'cloud-init=disabled',
                    'systemd.show_status=0', 'systemd.mask=serial-getty@ttyAMA0.service',
                    "systemd.run=\"/bin/bash /dev/disk/by-id/virtio-#{BATCH_SERIAL}\"",
                    'systemd.run_success_action=poweroff', 'systemd.run_failure_action=poweroff'].join(' ').freeze
    ALIGN = 1 << 20
    # The script and its calls fit the batch's first extent.
    SCRIPT_BYTES = ALIGN
    MEMORY_MIB = 2048
    CPUS = 2
    # A batch's deadlines: the boot, then each image's and probe's checks. A boot takes
    # under a minute and a batch of 19 corpus images under one more, so the guest test's
    # two batches end, even at their deadlines, within the test runner's 900 s for one
    # file (TEST_FILE_DEADLINE in tools/erx).
    BOOT_SECONDS = 120
    IMAGE_SECONDS = 15
    # The serial log read, at most: a 1 GiB probe's gzipped image is about 1.5 MiB of lines.
    SERIAL_BYTES = 64 << 20
    # A regular file's SHA-256 in a listing covers its first HASHED_BYTES, so a sparse file
    # of many GiB lists in seconds.
    HASHED_BYTES = 64 << 20
    PREFIX = 'erx-f2fs: '
    # Image names are the host's own, one token on a line.
    NAME = /\A[a-z0-9][a-z0-9_.-]{0,63}\z/
    RELEASE = /\A[0-9A-Za-z.+_~-]{1,64}\z/
    BASE64 = %r{\A[A-Za-z0-9+/]+=*\z}
    STEPS = %w[mkfs image fsck mount dmesg list].freeze
    STATUS_STEPS = %w[mkfs fsck mount list].freeze
    # Where a batch's images come from: erXos's own writes, or images made elsewhere,
    # hostile ones among them.
    ORIGINS = %i[erxos foreign].freeze
    # fsck.f2fs repairs some faults in check mode and still exits 0, so its output is
    # judged too (docs/design-f2fs.md, "The Linux oracle guest").
    FSCK_FAILURE = /\A(\[ASSERT\]|\[FIX\]|\[Fail\]|\[FSCK\] fixing)|Reconnect/
    # Lines of that form fsck.f2fs 1.16.0 prints on every fresh image of Linux's own
    # mkfs.f2fs too, each whole, so they say nothing about the image; the history record
    # notes/f2fs-oracle-2026-11-27 holds the probe.
    FSCK_BENIGN = ['[FSCK] fixing SIT types'].freeze
    # find's file type letters (its %y) by kind.
    KINDS = { 'f' => 'regular', 'd' => 'directory', 'l' => 'symlink', 'c' => 'character', 'b' => 'block', 'p' => 'fifo',
              's' => 'socket' }.freeze

    # One image of a batch: its name in the guest's lines, its file and its origin.
    Image = Data.define(:name, :path, :origin) do
      def initialize(name:, path:, origin: :erxos)
        raise Error, "f2fs oracle: image name #{name.inspect} is not a short lowercase token" unless name.is_a?(String) && name.match?(NAME)
        raise Error, "f2fs oracle: no image #{path}" unless File.file?(path)
        raise Error, "f2fs oracle: image #{path} is empty or not whole sectors" unless File.size(path).positive? && (File.size(path) % 512).zero?
        raise Error, "f2fs oracle: an image's origin is one of #{ORIGINS.join(', ')}" unless ORIGINS.include?(origin)

        super
      end
    end

    # One format of Linux's own in a batch: mkfs.f2fs's image of mib MiB, made with the
    # arguments (each a plain option or number), named name in the guest's lines.
    Probe = Data.define(:name, :mib, :arguments) do
      def initialize(name:, mib:, arguments: [])
        raise Error, "f2fs oracle: probe name #{name.inspect} is not a short lowercase token" unless name.is_a?(String) && name.match?(NAME)
        raise Error, 'f2fs oracle: a probe is 1 MiB to 2 GiB' unless mib.is_a?(Integer) && mib.between?(1, 2048)
        raise Error, 'f2fs oracle: probe arguments are plain options' unless arguments.all? { |argument| argument.match?(/\A-?[A-Za-z0-9]{1,16}\z/) }

        super(name: name, mib: mib, arguments: arguments.dup.freeze)
      end
    end

    # What the guest printed for one image: each step's output (bytes) it printed whole,
    # and each exit status.
    Result = Data.define(:outputs, :statuses)
    # A batch's lines read: the kernel release, each image's Result, and whether the
    # guest reached its end.
    Batch = Data.define(:kernel, :results, :done)

    module_function

    # The lock's sources over their own workspace.
    def lock(root:, runner:)
      SideLock.dependencies(root: root, runner: runner, lock: LOCK, workspace: WORKSPACE, label: LABEL)
    end

    # Fetches every source the lock pins, from cache when given. Answers what was done.
    def fetch(root:, runner:, cache: nil)
      SideLock.fetch(lock(root: root, runner: runner), root: root, label: LABEL, cache: cache)
    end

    # Why the guest cannot boot: the sources of its lock not fetched, or nil.
    def refusal(root:, runner:)
      dependencies = lock(root: root, runner: runner)
      missing = dependencies.sources.map { |source| source.fetch('id') }.reject { |id| dependencies.fetched?(id) }
      "the F2FS oracle guest needs #{missing.join(', ')}: run `#{SideLock.fetch_command(LABEL)}`" unless missing.empty?
    end

    # The pins a record of a batch keeps: each source's id, version and SHA-256.
    def pins(root:, runner:)
      lock(root: root, runner: runner).sources.map { |source| source.slice('id', 'version', 'sha256') }
    end

    # The script with its calls: the bytes a listing hashes, tools' extent, a check of each
    # image's, each probe and the end.
    def script(body, tools:, images:, probes: [])
      calls = ["hashed=#{HASHED_BYTES}", "tools #{tools.first} #{tools.last}",
               *images.map { |image, (offset, size)| "check #{image.name} #{offset} #{size}" },
               *probes.map { |probe| ['probe', probe.name, probe.mib, *probe.arguments].join(' ') }, 'finish']
      text = "#{body}#{calls.join("\n")}\n"
      raise Error, 'f2fs oracle: the batch script outgrows its extent' if text.bytesize > SCRIPT_BYTES

      text
    end

    # The extents [offset, size] of files laid out one after another from offset first,
    # each at a MiB-aligned offset.
    def extents(sizes, first:)
      sizes.each_with_object([]) do |size, placed|
        offset = placed.empty? ? first : align(placed.last.sum)
        placed << [offset, size]
      end
    end

    def align(offset) = (offset + ALIGN - 1) / ALIGN * ALIGN

    # Writes the batch disk at path: the script, f2fs-tools' package and images. An
    # all-zero MiB of an image is left a hole.
    def write_batch(path, body:, tools:, images:, probes: [])
      tools_extent, *image_extents = extents([tools, *images.map(&:path)].map { |file| File.size(file) }, first: SCRIPT_BYTES)
      text = script(body, tools: tools_extent, images: images.zip(image_extents), probes: probes)
      File.open(path, 'wb') do |disk|
        disk.write(text)
        [[tools, tools_extent], *images.map(&:path).zip(image_extents)].each do |file, (offset, size)|
          disk.seek(offset)
          copy_sparse(file, disk)
          disk.truncate(offset + size) if disk.size < offset + size
        end
      end
    end

    def copy_sparse(file, disk)
      File.open(file, 'rb') do |input|
        while (chunk = input.read(ALIGN))
          chunk.count("\0") == chunk.bytesize ? disk.seek(chunk.bytesize, IO::SEEK_CUR) : disk.write(chunk)
        end
      end
    end

    # Boots one batch of images and probes, its files in directory, which the caller owns;
    # answers the Batch read from the serial log and the QEMU report.
    def run(root:, runner:, images:, directory:, probes: [], accel: 'hvf')
      names = [*images, *probes].map(&:name)
      raise Error, 'f2fs oracle: a batch names each image and probe once' unless names.uniq.size == names.size
      raise Error, 'f2fs oracle: a batch holds images of one origin' unless images.map(&:origin).uniq.size <= 1
      refused = refusal(root: root, runner: runner)
      raise Error, refused if refused

      dependencies = lock(root: root, runner: runner)
      batch = File.join(directory, 'batch.img')
      write_batch(batch, body: File.binread(File.join(root, SCRIPT)), tools: dependencies.fetched_file(TOOLS), images: images,
                         probes: probes)
      disks = [QemuPlan::Disk.new(path: dependencies.fetched_file(ROOT_DISK), format: 'qcow2', access: :snapshot),
               QemuPlan::Disk.new(path: batch, access: :read, serial: BATCH_SERIAL)]
      checkpoints = [{ name: 'f2fs-oracle-kernel', pattern: /\Aerx-f2fs: kernel /n, seconds: BOOT_SECONDS },
                     { name: 'f2fs-oracle-done', pattern: /\Aerx-f2fs: done/n, seconds: IMAGE_SECONDS * names.size }]
      report = Qemu.new(root: root, runner: runner).run(
        platform: Platform.development(root), accel: accel, cpus: CPUS, memory_mib: MEMORY_MIB,
        image: dependencies.fetched_file(KERNEL), initrd: dependencies.fetched_file(INITRD),
        hostlink: QemuPlan::NO_HOSTLINK, command_line: COMMAND_LINE, disks: disks, checkpoints: checkpoints, bios: firmware,
        machine_end: true, directory: File.join(directory, 'qemu')
      )
      [read(serial_log(report.fetch('serial_log')), names: names), report]
    end

    # QEMU's own UEFI firmware for AArch64, beside the qemu-system-aarch64 on PATH.
    def firmware
      program = ENV.fetch('PATH', '').split(':').map { |dir| File.join(dir, 'qemu-system-aarch64') }.find { |path| File.executable?(path) }
      raise Error, 'f2fs oracle: no qemu-system-aarch64 on PATH' unless program

      path = File.expand_path('../share/qemu/edk2-aarch64-code.fd', File.dirname(File.realpath(program)))
      raise Error, "f2fs oracle: no UEFI firmware at #{path}" unless File.file?(path)

      path
    end

    # The serial log at path, refused past SERIAL_BYTES: at most that and one byte are read.
    def serial_log(path)
      bytes = File.open(path, 'rb') { |log| log.read(SERIAL_BYTES + 1) } || ''
      raise Error, "f2fs oracle: the serial log outgrows #{SERIAL_BYTES} bytes" if bytes.bytesize > SERIAL_BYTES

      bytes
    end

    # The guest's lines in serial, a log of untrusted bytes, read into a Batch for the
    # images and probes names. Other lines are the boot's. Refused: a line with the prefix
    # not of the grammar, the prefix anywhere but at a line's start, any line after
    # `done`, a name the batch never asked for, a step or status printed twice, and a
    # step whose chunks do not decode to the bytes its size line states, or that has no
    # size line, so a line the console lost or broke never passes as a shorter output.
    def read(serial, names:)
      chunks = Hash.new { |hash, key| hash[key] = +'' }
      outputs = Hash.new { |hash, key| hash[key] = {} }
      statuses = Hash.new { |hash, key| hash[key] = {} }
      kernel = nil
      done = false
      asked = ->(name, step, steps) { names.include?(name) && steps.include?(step) }
      guest_lines(serial).each do |line|
        refuse(line, 'after the batch ended') if done
        case line.delete_prefix(PREFIX).split(/ /, -1)
        in ['kernel', release] if kernel.nil? && release.match?(RELEASE) then kernel = release
        in ['out', name, step, chunk] if asked.(name, step, STEPS) && !outputs[name].key?(step) && chunk.match?(BASE64)
          chunks[[name, step]] << chunk
        in ['size', name, step, bytes, sha256] if asked.(name, step, STEPS) && !outputs[name].key?(step) &&
                                                  bytes.match?(/\A\d{1,12}\z/) && sha256.match?(/\A[0-9a-f]{64}\z/)
          outputs[name][step] = output(chunks.delete([name, step]) || '', bytes: Integer(bytes, 10), sha256: sha256, line: line)
        in ['exit', name, step, code] if asked.(name, step, STATUS_STEPS) && !statuses[name].key?(step) && code.match?(/\A\d{1,3}\z/)
          statuses[name][step] = Integer(code, 10)
        in ['done'] then done = true
        else refuse(line, 'of no known form')
        end
      end
      lost = chunks.keys.map { |name, step| "#{name} #{step}" }
      raise Error, "f2fs oracle: the guest printed no size line for #{lost.join(', ')}" unless lost.empty?

      silent = statuses.flat_map { |name, codes| (codes.keys - outputs[name].keys).map { |step| "#{name} #{step}" } }
      raise Error, "f2fs oracle: the guest printed a status but no output for #{silent.join(', ')}" unless silent.empty?

      results = (outputs.keys | statuses.keys).to_h do |name|
        [name, Result.new(outputs: outputs[name].dup.freeze, statuses: statuses[name].dup.freeze)]
      end
      Batch.new(kernel: kernel, results: results, done: done)
    end

    # The lines of serial that carry the prefix, each at its start.
    def guest_lines(serial)
      lines = serial.b.split(/\r?\n/).map { |line| line.delete("\r") }
      broken = lines.find { |line| line.include?(PREFIX) && !line.start_with?(PREFIX) }
      refuse(broken, 'with the prefix inside it') if broken
      lines.select { |line| line.start_with?(PREFIX) }
    end

    # A step's bytes from its base64 text, refused unless they are the bytes its size
    # line states.
    def output(text, bytes:, sha256:, line:)
      decoded = Base64.strict_decode64(text)
      refuse(line, "after #{decoded.bytesize} bytes of output") unless decoded.bytesize == bytes && Digest::SHA256.hexdigest(decoded) == sha256
      decoded
    rescue ArgumentError
      refuse(line, 'after output that is not base64')
    end

    def refuse(line, why)
      raise Error, "f2fs oracle: the guest printed a line #{why}: #{LineEscape.escape(line[0, 200])}"
    end

    # fsck.f2fs's verdict on one image: :pass, or the reason it fails.
    def fsck_verdict(result)
      code = result.statuses['fsck']
      return 'fsck.f2fs did not report its exit status' if code.nil?
      return "fsck.f2fs exited #{code}" unless code.zero?

      failed = result.outputs.fetch('fsck').split("\n").grep(FSCK_FAILURE) - FSCK_BENIGN
      failed.empty? ? :pass : "fsck.f2fs printed #{failed.size} failing lines, the first #{LineEscape.escape(failed.first[0, 200])}"
    end

    # The guest's record of a mounted tree as a listing: path (names joined by "/", the
    # root "") to kind, mode (the low 12 bits), links, size and content: the SHA-256 of
    # the regular file's first HASHED_BYTES, the symlink's target, the device's [major,
    # minor], or `!` where Linux would not let the guest read it.
    def listing(record)
      fields = record.b.split("\0", -1)
      raise Error, 'f2fs oracle: a tree record is not whole entries' unless fields.pop == '' && (fields.size % 6).zero?

      paths = fields.each_slice(6).map(&:first)
      raise Error, 'f2fs oracle: a tree record names a path twice' unless paths.uniq.size == paths.size

      fields.each_slice(6).to_h do |path, type, mode, links, size, content|
        kind = KINDS.fetch(type) { raise Error, "f2fs oracle: a file type of no known kind: #{LineEscape.escape(type)}" }
        device = %w[character block].include?(kind) && content != '!'
        raise Error, 'f2fs oracle: a tree record holds a number of no known form' unless [mode, links, size].all?(/\A[0-9]{1,20}\z/)

        [path == '.' ? '' : path.delete_prefix('./'),
         { kind: kind, mode: Integer(mode, 8) & 0o7777, links: Integer(links, 10), size: Integer(size, 10),
           content: device ? content.split(',').map { |part| Integer(part, 16) } : content }]
      end
    rescue ArgumentError, TypeError => e
      raise Error, "f2fs oracle: a tree record holds a field of no known form: #{LineEscape.escape(e.message[0, 200])}"
    end
  end
end
