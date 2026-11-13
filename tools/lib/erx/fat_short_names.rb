# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require_relative 'error'
require_relative 'fat_volume'

module Erx
  # The short (8.3) names in the root directory of slot A's FAT32 volume (PiMedium). The
  # Raspberry Pi's boot ROM reads only short names, so a file it loads (start4.elf,
  # fixup4.dat) must be stored under its own name in 8.3 form, not under a numbered alias
  # (F0000009) with a long name beside it. PiMedium checks every slot volume it writes
  # with this check, which reads the volume through FatVolume, which shares no code with
  # fsimg, the volume's writer. The case flags in byte 12 of an entry are Windows NT's
  # (0x08 base, 0x10 extension in lowercase).
  module FatShortNames
    # A part of a short name, written in one case: fsimg's rule (fsimg_fat_write_short_name)
    # restricted to the characters BootPartition::NAME allows.
    LOWER_PART = /\A[a-z0-9_-]+\z/
    UPPER_PART = /\A[A-Z0-9_-]+\z/

    # The short form a name takes: its 11 name bytes and the case flags that restore it.
    Short = Data.define(:name, :flags)

    module_function

    # The short form of name when it fits 8.3 with its base and extension each in a single
    # case, or nil when it needs a long name. Pure.
    def short_form(name)
      base, extension, extra = name.split('.', -1)
      return nil if extra || !part?(base, maximum: 8) || (extension && !part?(extension, maximum: 3))

      flags = (/[a-z]/.match?(base) ? 0x08 : 0) | (/[a-z]/.match?(extension.to_s) ? 0x10 : 0)
      Short.new(name: (base.upcase.ljust(8) + extension.to_s.upcase.ljust(3)).b, flags: flags)
    end

    # Whether part is a base or extension of at most maximum characters in one case. Pure.
    def part?(part, maximum:) = part.size.between?(1, maximum) && (LOWER_PART.match?(part) || UPPER_PART.match?(part))

    # Refuses the image at path unless each of names (root directory names) that fits 8.3
    # is a short entry of the root directory under that name with its case flags, and no
    # two short entries share a name.
    def check(path, names:)
      entries = root_entries(path)
      repeated = entries.map(&:name).tally.select { |_, count| count > 1 }.keys
      raise Error, "#{path}: the root directory repeats the short names #{repeated.map(&:inspect).join(', ')}" unless repeated.empty?

      flags = entries.to_h { |entry| [entry.name, entry.flags] }
      missing = names.filter_map do |name|
        short = short_form(name)
        name if short && flags[short.name] != short.flags
      end
      return if missing.empty?

      raise Error, "#{path}: the boot ROM reads only 8.3 names, and these are not stored as their own " \
                   "short names with their case flags: #{missing.join(', ')}"
    end

    # The short entries of the root directory of the volume at path, in order, without
    # deleted entries, long-name records and the volume label (FatVolume::Entry).
    def root_entries(path) = FatVolume.open(path, &:root_entries)
  end
end
