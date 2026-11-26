# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require_relative 'error'

module Erx
  # Tar archives from an untrusted source, read once on the host and written afresh as
  # plain ustar (docs/design-bench.md, "Genode's guest"). Two tar readers need not agree
  # on one archive: a V7 header's prefix field, bytes after a NUL in a name, extended
  # headers and a missing end block are each read differently by different readers. So
  # the reader the archive finally meets, a container engine's extracting it at the
  # container's root, is never handed the original: it gets the archive this module
  # writes from its own reading, in which every name, link target and size is the one
  # the check accepted, in the one header form every reader reads alike.
  #
  # The engine extracts several archives at one root over an image that has links of
  # its own, so the archives bound for one root are one reading (Root), and every
  # directory above an entry is written as a directory entry before it: the engine
  # follows a link of the image when it extracts a file beneath it, but refuses a
  # directory entry over anything that is not a directory (docker cp's
  # noOverwriteDirNonDir; moby v27.5.1 pkg/archive/archive.go, Unpack).
  #
  # Accepted: POSIX ustar and GNU headers with a valid checksum; regular files,
  # directories, symbolic links and hard links, and GNU long name and long link entries
  # of at most LONG_BYTES; every path under prefix, each but a directory named once by
  # the root's archives and none beneath a link or file of them; a symbolic link whose target is
  # relative, climbs only with leading "..", and stays under prefix; a hard link to an
  # earlier file; and the zero block that ends the archive. Written: first a "./"
  # directory entry, which the engine skips and which makes the archive's first bytes a
  # tar header's and no compressed stream's (the engine decompresses a stream that
  # starts with a compression magic, moby's DecompressStream); then each directory above
  # an entry, those above prefix too, once per root and with modification time 0, then
  # the entry; each with owner 0:0, directories 0755 and other entries their permission
  # bits within 0755, and the end blocks.
  module CheckedTar
    BLOCK = 512
    ZERO = ("\0" * BLOCK).b.freeze
    # One header's fields: name, mode, uid, gid, size, mtime, checksum, type flag, link
    # name, magic, version, user name, group name, device major and minor, prefix.
    LAYOUT = 'a100 a8 a8 a8 a12 a12 a8 a1 a100 a6 a2 a32 a32 a8 a8 a155'
    POSIX = ["ustar\0", '00'].freeze
    GNU = ['ustar ', " \0"].freeze
    TYPES = { '0' => :file, "\0" => :file, '1' => :hard, '2' => :symbolic, '5' => :directory }.freeze
    FLAGS = { file: '0', hard: '1', symbolic: '2', directory: '5' }.freeze
    LONG = { 'L' => :name, 'K' => :target }.freeze
    LONG_BYTES = 4096
    # The largest size or time eleven octal digits hold, the most a ustar field writes.
    NUMBER_MAX = 0o77777777777
    # A name's leading "./" or "/": entries are extracted beneath the root the engine is
    # given, and some archives name theirs from "/".
    LEADING = %r{\A\.?/}

    Entry = Data.define(:path, :type, :mode, :mtime, :size, :target)
    # The entry every written archive starts with.
    START = Entry.new(path: '.', type: :directory, mode: 0o755, mtime: 0, size: 0, target: '')

    # The archives the engine extracts at one root, in the order it extracts them: the
    # paths they have named, with their types. An archive's paths join the root's only
    # when the whole archive is accepted.
    class Root
      def initialize
        @seen = {}
      end

      # Reads the tar on input, refuses it (Erx::Error naming label) unless it is as the
      # module states against this root's earlier archives, and writes its entries to
      # output as a fresh ustar archive. Returns the number of entries written. output
      # holds a partial archive after a refusal.
      def rewrite(input, output, prefix:, label:)
        rewrite = Rewrite.new(input: input, output: output, prefix: prefix, label: label, seen: @seen.dup)
        count = rewrite.call
        @seen = rewrite.seen
        count
      end
    end

    # One pass over one archive: the root's paths with the archive's added (seen), and
    # the long name and long link target that the next header takes.
    class Rewrite
      attr_reader :seen

      def initialize(input:, output:, prefix:, label:, seen:)
        @input = input
        @output = output
        @prefix = prefix
        @label = label
        @seen = seen
        @long = {}
      end

      # The number of entries written, the leading "./" not counted.
      def call
        write(START)
        count = 0
        while (header = read(BLOCK, 'a header')) != ZERO
          entry = entry(header)
          next unless entry

          written = check(entry)
          written.each { |item| write(item) }
          count += written.size
        end
        refuse('a long name or link entry that no entry takes') unless @long.empty?
        @output.write(ZERO, ZERO)
        count
      end

      private

      # The entry header describes, checked, with its data left to copy; nil for a long
      # name entry, which the next header takes, and for the root directory.
      def entry(header)
        name, mode, _uid, _gid, size, mtime, checksum, flag, target, magic, version, *, prefix = header.unpack(LAYOUT)
        refuse('a header with a wrong checksum') unless number(checksum) == header.sum(0) - checksum.sum(0) + (8 * 32)
        refuse('a header that is neither POSIX ustar nor GNU tar') unless [POSIX, GNU].include?([magic, version])
        return long(LONG.fetch(flag), number(size)) if LONG.key?(flag)

        refuse("an entry of type #{flag.inspect}") unless TYPES.key?(flag)

        type = TYPES.fetch(flag)
        full = @long.delete(:name) || [([magic, version] == POSIX ? text(prefix) : ''), text(name)].reject(&:empty?).join('/')
        entry = Entry.new(path: full.sub(LEADING, '').delete_suffix('/'), type: type, mode: number(mode),
                          mtime: number(mtime), size: number(size), target: @long.delete(:target) || text(target))
        type == :directory && ['', '.'].include?(entry.path) ? nil : entry
      end

      def long(key, size)
        refuse("a long name over #{LONG_BYTES} bytes") unless size <= LONG_BYTES
        refuse('two long names for one entry') if @long.key?(key)

        @long[key] = text(read(padded(size), 'a long name').byteslice(0, size))
        nil
      end

      # Checks entry against the root's paths and records it; returns what to write for
      # it: each directory above it the root has not yet written, then the entry itself
      # unless it is a directory already written.
      def check(entry)
        path = entry.path
        inside = entry.type == :directory ? "#{path}/".start_with?(@prefix) : path.start_with?(@prefix)
        refuse("#{path.inspect}, which is not under ./#{@prefix}") unless inside && plain?(path.split('/', -1))
        refuse("#{path.inspect} twice") if @seen.key?(path) && [entry.type, @seen[path]] != %i[directory directory]
        refuse("#{path.inspect} with data") unless entry.size.zero? || entry.type == :file

        directories = ancestors(path)
        directories.each do |ancestor|
          refuse("#{path.inspect} beneath the #{@seen[ancestor]} #{ancestor.inspect}") unless
            [nil, :directory].include?(@seen[ancestor])
        end
        check_target(entry)
        above = directories.reject { |ancestor| @seen.key?(ancestor) }
        written = entry.type == :directory && @seen.key?(path) ? [] : [entry]
        above.each { |ancestor| @seen[ancestor] = :directory }
        @seen[path] = entry.type
        above.map { |ancestor| Entry.new(path: ancestor, type: :directory, mode: 0o755, mtime: 0, size: 0, target: '') } +
          written
      end

      # A symbolic link resolves against its own directory, which is a directory and no
      # link, so climbing with leading ".." alone reaches what its text says; a hard link
      # names a file the root's archives already hold.
      def check_target(entry)
        case entry.type
        when :symbolic
          parts = entry.target.split('/', -1)
          climbed = parts.drop_while { |part| part == '..' }
          directory = entry.path.split('/')[0...-1]
          kept = directory.size - (parts.size - climbed.size)
          resolved = (directory.first(kept) + climbed).join('/') unless kept.negative?
          refuse("the link #{entry.path.inspect} to #{entry.target.inspect}") unless
            !entry.target.empty? && plain?(climbed) && resolved && "#{resolved}/".start_with?(@prefix)
        when :hard
          refuse("the hard link #{entry.path.inspect} to #{entry.target.inspect}, not an earlier file") unless
            %i[file hard].include?(@seen[entry.target.sub(LEADING, '')])
        end
      end

      def write(entry)
        prefix, name = split(entry.type == :directory ? "#{entry.path}/" : entry.path)
        target = case entry.type
                 when :symbolic then entry.target
                 when :hard then entry.target.sub(LEADING, '')
                 else ''
                 end
        refuse("the link target #{target.inspect}, longer than ustar holds") unless target.bytesize <= 100

        mode = entry.type == :directory ? 0o755 : entry.mode & 0o755
        fields = [name, octal(mode, 7), octal(0, 7), octal(0, 7), octal(entry.size, 11), octal(entry.mtime, 11),
                  ' ' * 8, FLAGS.fetch(entry.type), target, *POSIX, '', '', octal(0, 7), octal(0, 7), prefix]
        header = fields.pack(LAYOUT).ljust(BLOCK, "\0")
        header[148, 8] = "#{octal(header.sum(0), 6)}\0 "
        @output.write(header)
        copy(entry.size) if entry.type == :file
      end

      def copy(size)
        refuse('a file cut short') unless IO.copy_stream(@input, @output, size) == size
        pad = padded(size) - size
        read(pad, 'padding')
        @output.write("\0" * pad)
      end

      # ustar's prefix and name of path: the whole path as the name when it fits, else
      # split at the first "/" that leaves a name of 1 to 100 bytes and a prefix of at
      # most 155, so the name is as long as its field allows.
      def split(path)
        return ['', path] if path.bytesize <= 100

        cut = (1...path.bytesize).find do |index|
          path[index] == '/' && index <= 155 && (path.bytesize - index - 1).between?(1, 100)
        end
        refuse("#{path.inspect}, longer than ustar holds") unless cut
        [path[0, cut], path[(cut + 1)..]]
      end

      def ancestors(path)
        parts = path.split('/')
        (1...parts.size).map { |count| parts.first(count).join('/') }
      end

      def plain?(parts) = parts.none? { |part| ['', '.', '..'].include?(part) }

      def padded(size) = (size + BLOCK - 1) / BLOCK * BLOCK

      # A text field: its bytes up to the NUL padding, refused when a NUL hides more.
      def text(field)
        value = field.sub(/\0+\z/, '')
        refuse("a name with bytes after a NUL: #{value.inspect}") if value.include?("\0")
        value
      end

      def number(field)
        digits = field[/\A *([0-7]{1,12})[ \0]*\z/, 1]
        refuse("a numeric field #{field.inspect}") unless digits
        refuse("a numeric field over #{NUMBER_MAX}") unless digits.to_i(8) <= NUMBER_MAX
        digits.to_i(8)
      end

      def octal(value, width) = format("%0#{width}o", value)

      def read(size, what)
        bytes = @input.read(size)
        refuse("#{what} cut before tar's end block") unless bytes&.bytesize == size
        bytes.b
      end

      def refuse(what) = raise(Error, "#{@label} holds #{what}")
    end
    private_constant :Rewrite
  end
end
