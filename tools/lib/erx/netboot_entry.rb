# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'digest'
require 'fileutils'
require 'openssl'
require_relative 'error'
require_relative 'boot_partition'
require_relative 'bounded_file'
require_relative 'fat_short_names'
require_relative 'fat_volume'
require_relative 'no_follow'
require_relative 'pi_medium'

module Erx
  # One entry of netboot's HTTP form (docs/design-platforms.md, "The HTTP form"): a
  # directory holding boot.img, a FAT32 volume of one boot set's files that the Pi 4's
  # bootloader loads whole as a RAM disk, and boot.sig, its signature in the format
  # rpi-eeprom-digest writes, which the bootloader checks against the key its EEPROM
  # holds before it boots the image. The image's cmdline.txt ends with the entry's boot
  # name (docs/design-bench.md, "The bench image's boot set"), so a boot that prints the
  # name ran this entry's whole set.
  #
  # This module owns the entry's format: write makes one, open_pair opens one for the boot
  # server or for a copy, and signing_key is the one reader of the signing key, which is
  # held only to sign and never written anywhere.
  module NetbootEntry
    IMAGE = 'boot.img'
    SIGNATURE = 'boot.sig'
    # The bootloader's RAM disk limit on the Pi 4, 180 MB (the firmware's boot_ramdisk
    # documentation, unverified here).
    MAX_IMAGE = 180 * 1000 * 1000
    # A signature is a digest line, a ts: line and a 512-digit RSA-2048 line.
    MAX_SIGNATURE = 1024
    # A kernel command line is far shorter.
    MAX_CMDLINE = 4096
    # A boot name: thirty-two lowercase hexadecimal digits (docs/design-bench.md, "The boot
    # name").
    NAME = /\A[0-9a-f]{32}\z/
    WORD = 'erx.arg='
    LABEL = 'ERXOSBOOT'
    KEY_BITS = 2048
    # A PEM RSA-2048 private key is under 2 KiB; anything far larger is not one.
    MAX_KEY = 16_384
    MIB = 1 << 20
    # The image's FAT32 has the card slot's 1 KiB clusters (PiMedium.fat_format) and
    # kernel8.img placed at the slot's boot start, so FAT32 by cluster count needs at
    # least 65,525 clusters after it: 64 MiB, and a MiB of room.
    MIN_IMAGE = PiMedium::BOOT_PLACE + (65 * MIB)
    # Room beside the files' clusters for directories and long names.
    SLACK = 4 * MIB
    # An entry directory's name in its queue: its number, from 1.
    NUMBER = /\A[1-9][0-9]{0,8}\z/

    # An entry's two files as open_pair opened them: the signature's bytes and the image
    # open read-only.
    Pair = Data.define(:signature, :image)

    module_function

    # Writes the entry directory, which must not exist, from files, a directory holding a
    # checked copy of a boot set whose files are names: boot.img of those files with
    # cmdline.txt ending in the boot name name, read back through FatVolume, and boot.sig
    # signed with key (signing_key). runner runs fsimg (Runner).
    def write(directory:, files:, names:, name:, key:, runner:, fsimg:)
      raise Error, "netboot: #{name.inspect} is not a boot name of thirty-two lowercase hexadecimal digits" unless
        NAME.match?(name)

      Dir.mkdir(directory, 0o755)
      staged = File.join(directory, 'files')
      listed = stage(files: files, names: names, name: name, to: staged)
      image = File.join(directory, IMAGE)
      runner.run([fsimg, 'cW', '-f', image, *PiMedium.fat_format(bytes: image_bytes(staged, listed), label: LABEL),
                  *PiMedium::PLACE, '-C', staged, '.'], name: 'fsimg-netboot-entry', deadline: PiMedium::VOLUME_DEADLINE)
      check(image, staged: staged, names: listed)
      File.write(File.join(directory, SIGNATURE), signature(image, key), perm: 0o644)
      FileUtils.rm_rf(staged)
    end

    # The RSA-2048 private key at path, opened once without following a symbolic link and
    # taken only from a regular file the user running the tool owns that grants no
    # permission to group or others (docs/design-bench.md, "The network boot the stager
    # drives"). No error names more of the file than its path.
    def signing_key(path)
      text = NoFollow.open(path, File::RDONLY | File::NONBLOCK) do |file|
        stat = file.stat
        raise Error, "netboot: the signing key #{path} is not a regular file" unless stat.file?
        raise Error, "netboot: the signing key #{path} is not owned by you" unless stat.uid == Process.euid
        raise Error, "netboot: the signing key #{path} grants permission to group or others; chmod 600 it" unless
          stat.mode.nobits?(0o077)

        file.read(MAX_KEY + 1).to_s
      end
      raise Error, "netboot: the signing key #{path} is larger than a key" if text.bytesize > MAX_KEY

      # An empty passphrase, so an encrypted key is refused rather than prompted for.
      key = OpenSSL::PKey::RSA.new(text, '')
      raise Error, "netboot: the signing key #{path} is no RSA-#{KEY_BITS} private key" unless
        key.private? && key.n.num_bits == KEY_BITS

      key
    rescue NoFollow::Link
      raise Error, "netboot: the signing key #{path} is a symbolic link; give the key file itself"
    rescue OpenSSL::PKey::PKeyError
      raise Error, "netboot: the signing key #{path} holds no RSA private key"
    rescue SystemCallError => e
      raise Error, "netboot: cannot open the signing key #{path}: #{e.class.name.split('::').last}"
    end

    # How many entries queue holds: its highest entry number, or 0.
    def entries(queue) = Dir.children(queue).grep(NUMBER).map(&:to_i).max || 0

    # The pair of entry directory directory, both files opened without following a link
    # and only when the directory and both are regular, or nil when it lacks either or
    # either cannot be read, which the boot server answers alike.
    def open_pair(directory)
      return nil unless File.lstat(directory).directory?

      signature = open_regular(File.join(directory, SIGNATURE))
      return nil unless signature

      bytes = begin
        signature.read(MAX_SIGNATURE + 1).to_s
      ensure
        signature.close
      end
      return nil if bytes.bytesize > MAX_SIGNATURE

      image = open_regular(File.join(directory, IMAGE))
      image && Pair.new(signature: bytes, image: image)
    rescue SystemCallError
      nil
    end

    # The file at path open read-only, or nil when it is missing, a link or not regular.
    def open_regular(path)
      file = NoFollow.open(path, File::RDONLY | File::NONBLOCK)
      return file.tap(&:binmode) if file.stat.file?

      file.close
      nil
    rescue SystemCallError, NoFollow::Link
      nil
    end

    # Links each of names from files into to, but cmdline.txt, which is written afresh
    # (command_line), so the set's copy is never changed. Returns the staged names.
    def stage(files:, names:, name:, to:)
      (names - [BootPartition::CMDLINE]).each do |file|
        target = File.join(to, file)
        FileUtils.mkdir_p(File.dirname(target))
        File.link(File.join(files, file), target)
      end
      FileUtils.mkdir_p(to)
      File.write(File.join(to, BootPartition::CMDLINE), command_line(files, names, name), perm: 0o644)
      (names | [BootPartition::CMDLINE])
    end

    # The entry's kernel command line: the set's line followed by the boot name word, or
    # that word alone when the set has none, with no newline (docs/design-bench.md, "The
    # boot name"). A set's line that holds a line break is refused, since the word after
    # it would not be on the line the firmware passes.
    def command_line(files, names, name)
      word = "#{WORD}#{name}"
      return word unless names.include?(BootPartition::CMDLINE)

      line = BoundedFile.read(File.join(files, BootPartition::CMDLINE), maximum: MAX_CMDLINE)
      raise Error, "netboot: the set's #{BootPartition::CMDLINE} holds a line break" if line.match?(/[\r\n]/)

      "#{line} #{word}"
    end

    # The image's size: the slot's boot start, each file in whole 1 KiB clusters and the
    # slack, in whole MiB, at least MIN_IMAGE; over MAX_IMAGE is refused.
    def image_bytes(staged, names)
      clusters = names.sum { |name| (File.size(File.join(staged, name)) + 1023) / 1024 }
      bytes = [((PiMedium::BOOT_PLACE + (clusters * 1024) + SLACK + MIB - 1) / MIB) * MIB, MIN_IMAGE].max
      raise Error, "netboot: boot.img would be #{bytes} bytes, over the bootloader's #{MAX_IMAGE}-byte RAM disk limit" if
        bytes > MAX_IMAGE

      bytes
    end

    # Reads image back through FatVolume, which shares no code with fsimg, as the card's
    # slot volume is (PiMedium.check_slot): kernel8.img placed, each root name stored as its
    # own short name, and every root file whose name is a short one, cmdline.txt with the
    # boot name among them, holding the staged bytes.
    def check(image, staged:, names:)
      roots = names.map { |name| name.split('/').first }.uniq
      PiMedium.check_slot(image, boot: BoundedFile.read(File.join(staged, PiMedium::BOOT_FILE), maximum: MAX_IMAGE),
                                 names: roots)
      FatVolume.open(image) do |volume|
        entries = volume.root_entries.to_h { |entry| [entry.name, entry] }
        names.reject { |name| name.include?('/') }.each do |name|
          short = FatShortNames.short_form(name)
          next unless short

          entry = entries[short.name] || volume.refuse("has no root entry for #{name}")
          volume.refuse("does not hold #{name} as staged") unless
            FatVolume.contents(volume, entry) == File.binread(File.join(staged, name))
        end
      end
    end

    # boot.sig of image: its SHA-256, the time it was signed and the RSA-2048 PKCS#1 v1.5
    # signature over that SHA-256, as rpi-eeprom-digest writes them.
    def signature(image, key)
      digest = Digest::SHA256.file(image)
      "#{digest.hexdigest}\nts: #{Time.now.to_i}\nrsa2048: #{key.sign_raw('SHA256', digest.digest).unpack1('H*')}\n"
    end

    private_class_method :open_regular, :stage, :command_line, :image_bytes, :check, :signature
  end
end
