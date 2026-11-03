# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'tmpdir'
require_relative 'error'
require_relative 'abi_binary'
require_relative 'bounded_file'
require_relative 'output_directory'

module Erx
  # The single bootable file (design-kernel.md, The bootable file): the first
  # stage as built with exactly its locator's two fields and its declared size
  # written, zeros up to a page boundary at or after its linked end, then the
  # archive unchanged. The two-file form needs no writing: it is the first
  # stage as built beside the archive.
  module BootFile
    # A first stage's linked size, zero-initialised data included. The file
    # holds zeros up to it, so an unchecked declared size cannot exhaust memory.
    FIRST_STAGE_MAX = 256 * 1024 * 1024

    module_function

    # Everything before the archive, a pure function of the first stage's
    # bytes and the archive's size.
    def head(codec:, first_stage:, archive_size:)
      page = codec.constant('page_size')
      unless archive_size.is_a?(Integer) && archive_size.positive? && (archive_size % page).zero?
        raise Error, 'the archive size must be a positive multiple of the page size'
      end
      header = decode(codec, 'erx_arch_boot_header', first_stage, 0)
      locator_offset = codec.constant('arch_boot_locator_offset')
      locator = decode(codec, 'erx_boot_locator', first_stage, locator_offset)
      raise Error, 'the first stage has no boot header' unless header.fetch('magic').b == codec.fixed_bytes('arch_boot_magic')
      unless locator.fetch('magic').b == codec.fixed_bytes('boot_locator_magic') &&
             locator.fetch('version') == codec.constant('boot_locator_version') && locator.fetch('zero').zero? &&
             locator.fetch('archive_off').zero? && locator.fetch('archive_size').zero?
        raise Error, 'the first stage does not carry a locator as built'
      end
      linked_end = header.fetch('image_size')
      unless linked_end.between?(first_stage.bytesize, FIRST_STAGE_MAX)
        raise Error, 'the first stage declares a size outside its own length and the bound'
      end

      archive_off = (linked_end + page - 1) / page * page
      bytes = first_stage.b + ("\0".b * (archive_off - first_stage.bytesize))
      place(codec, bytes, 'erx_boot_locator', locator_offset,
            locator.merge('archive_off' => archive_off, 'archive_size' => archive_size))
      place(codec, bytes, 'erx_arch_boot_header', 0, header.merge('image_size' => archive_off + archive_size))
      bytes.freeze
    end

    # The file appears at output whole or not at all: it is written in a
    # private directory beside output and renamed over it.
    def write(codec:, first_stage:, archive:, output:, output_root:)
      destination = File.expand_path(output)
      directory = OutputDirectory.prepare(root: output_root, path: File.dirname(destination))
      Dir.mktmpdir('.erx-boot-', directory) do |workspace|
        temporary = File.join(workspace, 'boot')
        assemble(codec, first_stage: first_stage, archive: archive, temporary: temporary)
        File.rename(temporary, File.join(directory, File.basename(destination)))
      end
    rescue SystemCallError => error
      raise Error, "cannot write the bootable file: #{error.message}"
    end

    # The archive must be a regular file whose header names this version and
    # its own length, so a wrong input is refused here and not only at boot.
    def assemble(codec, first_stage:, archive:, temporary:)
      stage = BoundedFile.read(first_stage, maximum: FIRST_STAGE_MAX)
      File.open(archive, File::RDONLY | File::NONBLOCK | File::BINARY) do |input|
        raise Error, 'the archive input is not a regular file' unless input.stat.file?

        size = input.stat.size
        check_archive(codec, input.read(codec.layout_size('erx_pack_header')), size)
        input.seek(0)
        File.open(temporary, File::WRONLY | File::CREAT | File::EXCL, 0o600) do |file|
          file.write(head(codec: codec, first_stage: stage, archive_size: size))
          raise Error, 'the archive changed size while it was copied' unless IO.copy_stream(input, file) == size

          file.flush
          file.fsync
        end
      end
    end
    private_class_method :assemble

    def check_archive(codec, bytes, size)
      header = decode(codec, 'erx_pack_header', bytes.to_s, 0)
      unless header.fetch('magic').b == codec.fixed_bytes('pack_magic') &&
             header.fetch('version') == codec.constant('pack_version') && header.fetch('total_size') == size
        raise Error, 'the archive input is not an archive of this version and length'
      end
    end
    private_class_method :check_archive

    def decode(codec, layout, bytes, offset)
      window = bytes.byteslice(offset, codec.layout_size(layout))
      raise Error, "the input is too short for #{layout}" unless window&.bytesize == codec.layout_size(layout)

      codec.decode_layout(layout, window)
    rescue ABI::DecodeError => error
      raise Error, "the input has no valid #{layout}: #{error.reason}"
    end
    private_class_method :decode

    # Fixed fields such as the magic are written by the encoder.
    def place(codec, bytes, layout, offset, values)
      encoded = codec.encode_layout(layout, values.reject { |key, _| key == 'magic' })
      bytes[offset, encoded.bytesize] = encoded
    end
    private_class_method :place
  end
end
