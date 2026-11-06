# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require_relative 'error'
require_relative 'runner'

module Erx
  # The EROFS oracle's manifest (docs/design-storage.md, Reading EROFS images): what one
  # reader of a set of EROFS images sees in each, as ASCII lines that the Linux guest
  # prints on its serial console and the EROFS reader prints on the host, so the two
  # views are parsed by one parser and compared by one function.
  #
  # Every line starts with PREFIX; lines without it (the guest kernel's own output) are
  # not the manifest's and are skipped. For images 0..n-1 in order, the lines are
  #
  #   image I
  #   entry PATH MODE SIZE UID GID NLINK MTIME INODE DATA   (one per file, any order)
  #   end I COUNT
  #
  # or `refused I REASON` when the reader does not mount image I, and last `done N`.
  # PATH, the file's names from the image's root joined by "/" ("/" for the root), is
  # hex, as is a link's text, so any byte a file name holds survives the console. MODE
  # is st_mode in hex, type bits included; the other numbers are decimal. DATA is "-"
  # for a directory or another non-regular file, `sha256:HEX` for a regular file's
  # contents, `link:HEX` for a link's text, or `error:REASON` when the reader could not
  # read the file. A mode of 0 marks a file whose metadata could not be read, and its
  # DATA is an error.
  #
  # Both views are untrusted input to the host: the guest's comes from a Linux kernel
  # parsing the image, through a serial console. The parser checks every field against
  # the bounds below and raises Erx::Error on the first line that breaks them, so a
  # malformed or truncated transcript is refused, never half-read.
  module ErofsManifest
    PREFIX = 'erx-erofs: '
    MAX_IMAGES = 64
    # Entries across all images, so a hostile transcript cannot fill the host's memory.
    MAX_ENTRIES = 1_000_000
    PATH_MAX = 4096
    MAX_LINE = 2 * PATH_MAX * 2 + 256
    U64_MAX = (1 << 64) - 1
    MODE_MAX = 0o177777
    TYPE_MASK = 0o170000
    TYPES = { 0o040000 => :directory, 0o100000 => :regular, 0o120000 => :symlink }.freeze
    # How many differences an image's comparison lists before it only counts them.
    SHOWN_DIFFERENCES = 20

    Entry = Data.define(:path, :mode, :size, :uid, :gid, :nlink, :mtime, :inode, :data) do
      def type = TYPES.fetch(mode & TYPE_MASK, mode.zero? ? :unknown : :other)
    end
    # One image's view: its entries by path, or the reason the reader refused it.
    View = Data.define(:entries, :refusal)

    TOKEN = /\A[a-z0-9_]{1,32}\z/
    HEX = /\A(?:[0-9a-f]{2})+\z/
    DECIMAL = /\A(?:0|[1-9][0-9]{0,19})\z/

    module_function

    # Parses the manifest lines in text into an array of Views, one per image, in order.
    def parse(text)
      state = { images: [], current: nil, done: false, entries: 0 }
      text = text.b unless text.encoding == Encoding::BINARY
      text.each_line("\n").with_index(1) do |raw, number|
        line = raw.chomp("\n").chomp("\r")
        next unless line.start_with?(PREFIX)
        raise Error, 'manifest line too long' if line.bytesize > MAX_LINE
        raise Error, 'manifest line after done' if state[:done]

        begin
          step(state, line.byteslice(PREFIX.bytesize..).split(/ /, -1))
        rescue Error => error
          raise Error, "line #{number}: #{error.message}"
        end
      end
      raise Error, 'manifest has no done line' unless state[:done]

      state[:images].freeze
    end

    def step(state, fields)
      case fields
      in ['image', index]
        expect_next(state, index)
        state[:current] = {}
      in ['entry', *rest] if state[:current]
        entry = parse_entry(rest)
        raise Error, 'manifest has too many entries' if state[:entries] >= MAX_ENTRIES
        raise Error, 'manifest repeats a path' if state[:current].key?(entry.path)

        state[:current][entry.path] = entry
        state[:entries] += 1
      in ['end', index, count] if state[:current]
        unless number(index) == state[:images].size && number(count) == state[:current].size
          raise Error, 'manifest image ends out of order or with the wrong count'
        end
        state[:images] << View.new(entries: state[:current].freeze, refusal: nil)
        state[:current] = nil
      in ['refused', index, reason] if state[:current].nil?
        expect_next(state, index)
        raise Error, 'manifest refusal reason is malformed' unless TOKEN.match?(reason)

        state[:images] << View.new(entries: nil, refusal: reason)
      in ['done', count] if state[:current].nil?
        raise Error, 'manifest done count differs from its images' unless number(count) == state[:images].size

        state[:done] = true
      else
        raise Error, 'malformed manifest line'
      end
    end

    def expect_next(state, index)
      raise Error, 'manifest images out of order' unless state[:current].nil? && number(index) == state[:images].size
      raise Error, 'manifest has too many images' if state[:images].size >= MAX_IMAGES
    end

    def parse_entry(fields)
      raise Error, 'manifest entry has the wrong number of fields' unless fields.size == 9

      path, mode, *numbers, data = fields
      raise Error, 'manifest mode is malformed' unless /\A[0-9a-f]{1,6}\z/.match?(mode) && mode.to_i(16) <= MODE_MAX

      size, uid, gid, nlink, mtime, inode = numbers.map { |field| number(field) }
      entry = Entry.new(path: parse_path(path), mode: mode.to_i(16), size: size, uid: uid, gid: gid, nlink: nlink,
                        mtime: mtime, inode: inode, data: parse_data(data))
      check_data(entry)
      entry
    end

    # A path is "/" or "/" followed by names, each non-empty, not "." or "..", without
    # NUL or "/", at most PATH_MAX bytes in all.
    def parse_path(field)
      path = unhex(field, limit: PATH_MAX)
      return path if path == '/'

      names = path.split('/', -1)
      unless names.first == '' && names.size >= 2 &&
             names.drop(1).none? { |name| name.empty? || name == '.' || name == '..' || name.include?("\0") }
        raise Error, 'manifest path is malformed'
      end
      path
    end

    def parse_data(field)
      case field
      when '-' then [:none]
      when /\Asha256:([0-9a-f]{64})\z/ then [:sha256, Regexp.last_match(1)]
      when /\Alink:(.*)\z/
        text = unhex(Regexp.last_match(1), limit: PATH_MAX - 1)
        raise Error, 'manifest link text holds a NUL' if text.include?("\0")

        [:link, text]
      when /\Aerror:(.*)\z/
        raise Error, 'manifest error reason is malformed' unless TOKEN.match?(Regexp.last_match(1))

        [:error, Regexp.last_match(1)]
      else raise Error, 'manifest data is malformed'
      end
    end

    # Each type carries only its own kind of data; any type may carry an error instead.
    def check_data(entry)
      kind = entry.data.first
      return if kind == :error

      expected = { regular: :sha256, symlink: :link, directory: :none, other: :none }.fetch(entry.type, :error)
      raise Error, 'manifest data does not match the file type' unless kind == expected
    end

    def number(field)
      raise Error, 'manifest number is malformed' unless DECIMAL.match?(field) && field.to_i <= U64_MAX

      field.to_i
    end

    def unhex(field, limit:)
      unless HEX.match?(field) && field.bytesize <= 2 * limit
        raise Error, 'manifest hex field is malformed or too long'
      end

      [field].pack('H*').b.freeze
    end

    # Compares the reader's view of one image with Linux's and answers the differences,
    # each a line of escaped text: an empty list when the two agree, the reader's
    # refusal when it refused the image.
    def compare(linux:, reader:)
      return ['Linux did not mount the image'] if linux.refusal
      return ["the reader refused the image: #{reader.refusal}"] if reader.refusal

      paths = (linux.entries.keys | reader.entries.keys).sort
      differences = paths.flat_map { |path| differences(path, linux.entries[path], reader.entries[path]) }
      return differences if differences.size <= SHOWN_DIFFERENCES

      [*differences.first(SHOWN_DIFFERENCES), "and #{differences.size - SHOWN_DIFFERENCES} more differences"]
    end

    def differences(path, linux, reader)
      name = Terminal.escape(path)
      return ["#{name}: only the reader sees it"] unless linux
      return ["#{name}: only Linux sees it"] unless reader

      Entry.members.reject { |field| linux.public_send(field) == reader.public_send(field) }.map do |field|
        "#{name}: #{field} is #{show(linux.public_send(field))} under Linux, #{show(reader.public_send(field))} in the reader"
      end
    end

    def show(value) = Terminal.escape(value.is_a?(Array) ? value.join(':') : value)

    private_class_method :step, :expect_next, :parse_entry, :parse_path, :parse_data, :check_data, :number, :unhex,
                         :differences, :show
  end
end
