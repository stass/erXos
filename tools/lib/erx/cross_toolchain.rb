# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require_relative 'error'
require_relative 'host_path'

module Erx
  # The AArch64 ELF cross GCC and binutils that build the stopgap Fiasco
  # (docs/design-stopgap.md). Hosts install them under one of two prefixes:
  # Homebrew's aarch64-elf-gcc and aarch64-elf-binutils as `aarch64-elf-`,
  # FreeBSD's devel/aarch64-none-elf-gcc port as `aarch64-none-elf-`. find
  # decides the prefix once per build; the Fiasco build passes the Toolchain
  # it returns to everything that runs or records a cross program
  # (CROSS_COMPILE, gcc, g++, as, nm, ar, objcopy, GCC's lib/gcc/<target>
  # directory), and each derives the name from it.
  module CrossToolchain
    # In order of preference: where both are installed, Homebrew's wins.
    PREFIXES = %w[aarch64-elf- aarch64-none-elf-].freeze
    # The programs a prefix must have to count: GCC's C and C++ drivers
    # (Fiasco is C++) and the binutils' assembler.
    PROBES = %w[gcc g++ as].freeze

    # prefix is what the inherited make system takes as CROSS_COMPILE; it is
    # always one of PREFIXES, so the names derived from it are fixed text.
    Toolchain = Data.define(:prefix) do
      def initialize(prefix:)
        raise Error, "unknown AArch64 cross prefix: #{prefix.inspect}" unless PREFIXES.include?(prefix)

        super
      end

      # The cross program of that name, as found on PATH: program('nm').
      def program(name) = "#{prefix}#{name}"

      # GCC's target name, which names its lib/gcc/<target> directory.
      def target = prefix.delete_suffix('-')
    end

    module_function

    # The first of PREFIXES whose PROBES are all executables in path's
    # absolute directories (HostPath), or an error naming both prefixes.
    def find(path: ENV.fetch('PATH', ''))
      directories = HostPath.directories(path)
      prefix = PREFIXES.find do |candidate|
        PROBES.all? { |probe| HostPath.find_program(candidate + probe, directories: directories) }
      end
      raise Error, missing_message unless prefix

      Toolchain.new(prefix: prefix)
    end

    # "... neither aarch64-elf-gcc, aarch64-elf-g++ and aarch64-elf-as nor
    # aarch64-none-elf-gcc, aarch64-none-elf-g++ and aarch64-none-elf-as ...".
    def missing_message
      choices = PREFIXES.map do |prefix|
        names = PROBES.map { |probe| prefix + probe }
        "#{names[0...-1].join(', ')} and #{names.last}"
      end
      "missing the AArch64 cross GCC and binutils: PATH's absolute directories hold neither #{choices.join(' nor ')}; " \
        'install one set (README.md, "Host setup")'
    end
  end
end
