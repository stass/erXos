# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'digest'
require_relative 'error'

module Erx
  module Web
    # The client's files as `make web` leaves them in build/web/ (docs/design-web.md,
    # "The client"): inventory.txt lists each file as its SHA-256 in hexadecimal, two
    # spaces and its path, sha256sum's format, one per line. load reads that list and
    # each file once, checks every hash, and keeps the bytes; this is the front end's
    # one read of host files, so no URL ever names a file on the host, and a file
    # changed after the build fails the start instead of being served.
    class Inventory
      LIST = 'inventory.txt'
      INDEX = 'index.html'
      # A path of segments that each start with a letter, digit, '_' or '-': none is '.',
      # '..' or hidden, and none holds a byte a URL would have to escape.
      NAME = %r{\A[A-Za-z0-9_-][A-Za-z0-9._-]*(?:/[A-Za-z0-9_-][A-Za-z0-9._-]*)*\z}
      LINE = /\A(\h{64})  (.+)\z/
      # The content type of each kind of file the client has; a file of any other kind
      # stops the load, so nothing is served as a type a browser would guess.
      TYPES = { '.html' => 'text/html; charset=utf-8', '.js' => 'text/javascript; charset=utf-8',
                '.css' => 'text/css; charset=utf-8', '.txt' => 'text/plain; charset=utf-8' }.freeze
      FILES_MAX = 256
      BYTES_MAX = 64 << 20

      # path is the file's name in the bundle, with no leading '/'.
      Entry = Data.define(:path, :content_type, :bytes)

      # The bundle that directory's inventory lists.
      def self.load(directory)
        list = File.join(directory, LIST)
        raise Error, "the web client is not built: no #{list}" unless File.file?(list)

        entries = File.binread(list).split("\n").map do |line|
          digest, path = line.match(LINE)&.captures
          raise Error, "#{list}: a line that is not a SHA-256, two spaces and a path" unless digest && path.match?(NAME)

          full = File.join(directory, path)
          raise Error, "#{list}: #{path} is not a plain file" unless File.lstat(full).file?

          bytes = File.binread(full)
          raise Error, "#{list}: #{path} does not have the SHA-256 the inventory lists" unless
            Digest::SHA256.hexdigest(bytes) == digest.downcase

          [path, bytes]
        end
        new(entries)
      end

      # entries is [path, bytes] for each file.
      def initialize(entries)
        raise Error, "the web client's inventory lists #{entries.size} files, more than #{FILES_MAX}" if
          entries.size > FILES_MAX
        raise Error, "the web client's files are over #{BYTES_MAX} bytes" if entries.sum { |_, bytes| bytes.bytesize } > BYTES_MAX

        @files = entries.to_h do |path, bytes|
          type = TYPES[File.extname(path)]
          raise Error, "the web client's #{path} is not a file of a kind the front end serves" unless type && path.match?(NAME)

          [path, Entry.new(path: path, content_type: type, bytes: bytes.b.freeze)]
        end.freeze
        raise Error, "the web client's inventory lists a path twice" unless @files.size == entries.size
        raise Error, "the web client has no #{INDEX}" unless @files.key?(INDEX)
      end

      # The file a request's path names, by its exact bytes, or index.html for any other
      # path: the client routes every other path itself (docs/design-web.md, "URLs").
      def file(request_path) = @files.fetch(request_path.delete_prefix('/'), @files.fetch(INDEX))

      def paths = @files.keys
    end
  end
end
