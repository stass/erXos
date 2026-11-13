# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'digest'
require_relative 'error'

module Erx
  # A picture the guest's display showed, as QEMU's screendump writes it (format ppm): binary
  # PPM (P6), 8 bits per channel. The decoder reads bytes QEMU produced from a surface whose
  # size the guest chose, so every field is bounds-checked before it sizes anything: the header
  # is a few short tokens within the first HEADER_MAX bytes, the picture is at most MAX_PIXELS
  # pixels, and the pixel bytes are exactly width * height * 3, no fewer and no more.
  module Ppm
    class FormatError < Error; end

    # The longest header a picture has: "P6", three numbers, comments and white space.
    HEADER_MAX = 256
    # The longest decimal number in a header; 8 digits cannot overflow and none is a size.
    NUMBER_DIGITS_MAX = 8
    # The most pixels of a picture (4096 x 4096), and so at most 48 MiB of pixel bytes.
    MAX_PIXELS = 16_777_216
    # The most bytes of a picture file read from disk: the header and the most pixels.
    MAX_FILE_BYTES = HEADER_MAX + (MAX_PIXELS * 3)
    WHITE_SPACE = [0x20, 0x09, 0x0a, 0x0b, 0x0c, 0x0d].freeze

    # A decoded picture: rows of RGB888 (red, green, blue, one byte each), top row first,
    # in pixels, one binary string of width * height * 3 bytes.
    Image = Data.define(:width, :height, :pixels) do
      def initialize(width:, height:, pixels:)
        valid = width.is_a?(Integer) && height.is_a?(Integer) && pixels.is_a?(String) &&
                width.positive? && height.positive? && width * height <= MAX_PIXELS &&
                pixels.bytesize == width * height * 3
        raise FormatError, 'an image is width * height RGB888 pixels within the size limit' unless valid

        super(width: width, height: height, pixels: pixels.b.freeze)
      end

      # One row of the picture, y from 0 at the top: width * 3 bytes.
      def row(y)
        raise FormatError, "row #{y} is outside the image" unless y.is_a?(Integer) && y.between?(0, height - 1)

        pixels.byteslice(y * width * 3, width * 3)
      end

      def rows = Array.new(height) { |y| row(y) }

      # What "equals the reference" means (docs/design-display.md): the SHA-256 of the
      # picture's size as two big-endian 32-bit numbers, then its pixel bytes, in hex. The
      # file's encoding (comments, white space) and the encoder never matter.
      def digest = Digest::SHA256.hexdigest([width, height].pack('NN') + pixels)

      # The picture as a binary PPM file, for a person to look at when a comparison fails.
      def to_ppm = "P6\n#{width} #{height}\n255\n".b + pixels
    end

    module_function

    # The Image in bytes, a binary PPM with maxval 255; anything else raises FormatError.
    def decode(bytes)
      raise FormatError, 'a PPM is a string of bytes' unless bytes.is_a?(String)

      data = bytes.b
      raise FormatError, 'not a binary PPM (P6)' unless data.byteslice(0, 2) == 'P6'

      cursor = 2
      numbers = Array.new(3) do
        number, cursor = number_at(data, cursor)
        number
      end
      width, height, maxval = numbers
      raise FormatError, "maxval #{maxval} is not 255" unless maxval == 255
      raise FormatError, "image size #{width} x #{height} is not allowed" unless
        width.positive? && height.positive? && width * height <= MAX_PIXELS

      # Exactly one white space byte follows maxval, then the pixels begin.
      raise FormatError, 'no white space after maxval' unless WHITE_SPACE.include?(data.getbyte(cursor))

      body = cursor + 1
      expected = width * height * 3
      unless data.bytesize - body == expected
        raise FormatError, "pixel data is #{data.bytesize - body} bytes, not the #{expected} that #{width} x #{height} takes"
      end

      Image.new(width: width, height: height, pixels: data.byteslice(body, expected))
    end

    # The Image in a PPM file QEMU wrote. The file must be a regular file (never a link) and
    # no larger than the size limit allows.
    def read_file(path)
      File.open(path, File::RDONLY | File::NOFOLLOW | File::NONBLOCK) do |file|
        stat = file.stat
        raise FormatError, "#{path} is not a regular file" unless stat.file?
        raise FormatError, "#{path} is larger than a picture can be" if stat.size > MAX_FILE_BYTES

        decode(file.read(MAX_FILE_BYTES + 1))
      end
    rescue SystemCallError => e
      raise FormatError, "cannot read #{path}: #{e.class.name.split('::').last}"
    end

    # The number after white space and comments from cursor, and the cursor past its last
    # digit. A number is 1 to NUMBER_DIGITS_MAX decimal digits and begins within HEADER_MAX.
    def number_at(data, cursor)
      cursor = skip_blanks(data, cursor)
      first = cursor
      cursor += 1 while digit?(data.getbyte(cursor))
      digits = cursor - first
      raise FormatError, 'expected a number in the PPM header' if digits.zero?
      raise FormatError, 'a number in the PPM header is too long' if digits > NUMBER_DIGITS_MAX

      [Integer(data.byteslice(first, digits), 10), cursor]
    end

    # The cursor past white space and `#` comments (to the end of the line), within HEADER_MAX.
    def skip_blanks(data, cursor)
      loop do
        raise FormatError, 'the PPM header is too long' if cursor >= HEADER_MAX

        byte = data.getbyte(cursor)
        if WHITE_SPACE.include?(byte)
          cursor += 1
        elsif byte == 0x23
          cursor += 1 until cursor >= HEADER_MAX || [0x0a, nil].include?(data.getbyte(cursor))
        else
          return cursor
        end
      end
    end

    def digit?(byte) = !byte.nil? && byte.between?(0x30, 0x39)
  end
end
