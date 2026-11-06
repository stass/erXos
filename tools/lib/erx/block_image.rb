# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require_relative 'error'

module Erx
  # A raw disk image whose every sector holds a known pattern, made for a guest to
  # read, and a checker that reads the image after the guest ran and says, sector
  # by sector, whether it still holds the pattern expected there. The harness
  # creates the image in a run directory it owns; the checker trusts nothing about
  # the file the guest wrote through: it opens the path without following a link
  # in its last component,
  # refuses anything but a bounded regular file, and reads one sector at a time.
  module BlockImage
    SECTOR_BYTES = 512
    # 2 MiB: far more than a test needs, and a bound on every read and write.
    MAX_SECTORS = 4096
    # Eight bytes each. The host's tag fills sectors the host made; the guest's tag
    # is what the guest writes, so a sector's content says who wrote it.
    HOST_TAG = 'ERXHOST!'
    GUEST_TAG = 'ERXGUEST'
    RECORD_BYTES = 16
    NAME = /\A[a-z0-9][a-z0-9._-]{0,63}\z/

    # The verdict on one sector: :match, :differ, or :out_of_range when the index
    # lies outside the image or beyond the end of the file.
    SectorResult = Data.define(:index, :status)

    module_function

    # Sector index with the tag: a 16-byte record of the tag and the index as a
    # little-endian 64-bit number, repeated to fill the sector. The same tag in
    # two sectors never gives the same bytes.
    def pattern(index, tag:)
      raise Error, 'a sector index is a non-negative integer below 2**64' unless index.is_a?(Integer) && index.between?(0, (2**64) - 1)
      raise Error, 'a sector tag is eight ASCII bytes' unless tag.is_a?(String) && tag.bytesize == 8 && tag.ascii_only?

      ((tag.b + [index].pack('Q<')) * (SECTOR_BYTES / RECORD_BYTES)).freeze
    end

    # Writes a new image of sectors sectors, each holding the host's pattern, as
    # name in directory, which the caller has made and owns. An existing name is
    # refused, and a link in the name is never followed; directory is a path the
    # caller made with OutputDirectory, since a linked directory is followed.
    # Returns the image's path.
    def create(directory:, name:, sectors:, tag: HOST_TAG)
      check_sectors(sectors)
      raise Error, 'a disk image name is a plain file name' unless name.is_a?(String) && NAME.match?(name)
      raise Error, 'the disk image directory is not a directory' unless directory.is_a?(String) && File.directory?(directory)

      path = File.join(File.realpath(directory), name)
      flags = File::WRONLY | File::CREAT | File::EXCL | File::NOFOLLOW
      File.open(path, flags, 0o600) do |output|
        output.binmode
        sectors.times { |index| output.write(pattern(index, tag: tag)) }
      end
      path
    rescue SystemCallError, IOError => error
      raise Error, "cannot create disk image: #{error.message}"
    end

    # Reads each sector in expected, a map from sector index to the tag it must
    # hold, from the image at path, which has sectors sectors. Returns a
    # SectorResult per entry, in index order. A sector the file does not wholly
    # contain is :out_of_range, however the file came to be short.
    def check(path:, sectors:, expected:)
      check_sectors(sectors)
      unless expected.is_a?(Hash) && expected.size <= MAX_SECTORS && expected.keys.all?(Integer)
        raise Error, "a disk image check expects at most #{MAX_SECTORS} sectors, named by integers"
      end

      open_image(path) do |size, input|
        expected.sort.map do |index, tag|
          SectorResult.new(index: index, status: sector_status(input, size: size, sectors: sectors, index: index, tag: tag))
        end
      end
    end

    # The sector indexes of results that have the given status.
    def indexes(results, status)
      results.select { |result| result.status == status }.map(&:index)
    end

    def check_sectors(sectors)
      return if sectors.is_a?(Integer) && sectors.between?(1, MAX_SECTORS)

      raise Error, "a disk image has 1 to #{MAX_SECTORS} sectors"
    end
    private_class_method :check_sectors

    def sector_status(input, size:, sectors:, index:, tag:)
      return :out_of_range unless index.between?(0, sectors - 1) && (index + 1) * SECTOR_BYTES <= size

      input.pread(SECTOR_BYTES, index * SECTOR_BYTES) == pattern(index, tag: tag) ? :match : :differ
    end
    private_class_method :sector_status

    # Opens path for reading, and yields its size and the open file.
    def open_image(path)
      unless path.is_a?(String) && path.start_with?('/') && path.bytesize <= 4096 && !path.include?("\0")
        raise Error, 'a disk image path is absolute, short and holds no NUL'
      end

      File.open(path, File::RDONLY | File::NOFOLLOW | File::NONBLOCK) do |input|
        stat = input.stat
        raise Error, "disk image is not a bounded regular file: #{path}" unless stat.file? && stat.size <= MAX_SECTORS * SECTOR_BYTES

        input.binmode
        yield stat.size, input
      end
    rescue SystemCallError, IOError => error
      raise Error, "cannot read disk image: #{error.message}"
    end
    private_class_method :open_image
  end
end
