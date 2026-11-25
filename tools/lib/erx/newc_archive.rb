# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require_relative 'error'

module Erx
  # A cpio archive in the newc format ("070701"), the form Linux unpacks as its
  # initramfs (docs/design-bench.md, "Linux's guest"), written without mknod or cpio
  # on the host: a device node is a header, not a file the host makes. Each entry's
  # path is relative and made of plain names, so the archive names nothing outside the
  # root it is unpacked into, and each directory precedes what it holds. Owners are
  # root and every time is zero, so the same entries give the same bytes.
  module NewcArchive
    class Invalid < Error; end

    MAGIC = '070701'
    TRAILER = 'TRAILER!!!'
    # A path component: no separators, no "." or "..", nothing but these characters, and
    # no longer than a Linux file name (NAME_MAX).
    COMPONENT = /\A(?!\.{1,2}\z)[A-Za-z0-9._+-]{1,255}\z/
    TYPES = { directory: 0o040000, file: 0o100000, character: 0o020000 }.freeze

    # One archive member: a directory, a regular file with its bytes, or a character
    # device with its major and minor numbers.
    Entry = Data.define(:path, :type, :mode, :data, :major, :minor) do
      def self.directory(path, mode: 0o755) = new(path: path, type: :directory, mode: mode, data: ''.b, major: 0, minor: 0)
      def self.file(path, data, mode:) = new(path: path, type: :file, mode: mode, data: data, major: 0, minor: 0)
      def self.character(path, major:, minor:, mode: 0o600)
        new(path: path, type: :character, mode: mode, data: ''.b, major: major, minor: minor)
      end

      def initialize(path:, type:, mode:, data:, major:, minor:)
        components = path.is_a?(String) ? path.split('/', -1) : []
        unless !components.empty? && components.all? { |name| COMPONENT.match?(name) }
          raise Invalid, "initramfs path #{path.inspect} is not relative plain names"
        end
        raise Invalid, "#{path}: mode is not permission bits" unless mode.is_a?(Integer) && mode.between?(0, 0o7777)
        raise Invalid, "#{path}: data is not bytes" unless data.is_a?(String) && data.encoding == Encoding::BINARY
        raise Invalid, "#{path}: device numbers out of range" unless [major, minor].all? { |n| n.is_a?(Integer) && n.between?(0, 0xfff) }

        raise Invalid, "#{path}: unknown type" unless TYPES.key?(type)

        super(path: path.freeze, type: type, mode: mode, data: data.dup.freeze, major: major, minor: minor)
      end

      def parent = path.include?('/') ? File.dirname(path) : nil
    end

    module_function

    # The archive of entries, in their order, ended by the trailer.
    def write(entries)
      directories = []
      entries.each do |entry|
        raise Invalid, "#{entry.path} appears twice" if entries.count { |other| other.path == entry.path } > 1
        raise Invalid, "#{entry.path} precedes its directory" unless entry.parent.nil? || directories.include?(entry.parent)

        directories << entry.path if entry.type == :directory
      end
      members = entries.each_with_index.map do |entry, index|
        member(entry.path, inode: index + 1, mode: TYPES.fetch(entry.type) | entry.mode,
                           nlink: entry.type == :directory ? 2 : 1, data: entry.data, rdev: [entry.major, entry.minor])
      end
      [*members, member(TRAILER, inode: 0, mode: 0, nlink: 1, data: ''.b, rdev: [0, 0])].join.b
    end

    # One header, its NUL-ended name and its data, each padded to four bytes.
    def member(name, inode:, mode:, nlink:, data:, rdev:)
      fields = [inode, mode, 0, 0, nlink, 0, data.bytesize, 0, 0, *rdev, name.bytesize + 1, 0]
      header = MAGIC + fields.map { |field| format('%08x', field) }.join
      pad(header + name + "\0") + pad(data)
    end

    def pad(bytes) = bytes.b + ("\0" * (-bytes.bytesize % 4))
    private_class_method :member, :pad
  end
end
