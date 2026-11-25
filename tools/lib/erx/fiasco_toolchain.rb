# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require_relative 'error'
require_relative 'host_path'

module Erx
  # The LLVM toolchain that builds Fiasco and L4Re (docs/design-fiasco.md,
  # "Toolchain"): compiler is clang (ERX_CLANG), linker is ld.lld (ERX_LLD),
  # and LLVM's binary tools are those installed beside clang, as every other
  # erXos build finds them. The inherited make systems read the toolchain
  # from each build directory's Makeconf.local (kernel_settings,
  # user_settings), not from the command line, where a CC would override
  # the target flag they add. CROSS_COMPILE only names the target triple
  # they pass to clang; no program of that prefix runs.
  FiascoToolchain = Data.define(:compiler, :linker) do
    # A bare linker name is found as every other build finds ERX_LLD (HostPath.find_linker).
    def initialize(compiler:, linker:, path: ENV.fetch('PATH', ''))
      unless compiler.to_s.start_with?('/') && !linker.to_s.empty?
        raise Error, "the Fiasco build needs ERX_CLANG and ERX_LLD, LLVM's clang as an absolute path and its ld.lld"
      end
      unless File.file?(compiler) && File.executable?(compiler)
        raise Error, "ERX_CLANG names no executable compiler: #{compiler.inspect}"
      end

      # One spelling for every caller: settings, records and keys name the installed
      # programs, whichever link the environment names, so siblings come from the real
      # installation. ld.lld keeps its name, by which the multi-call lld knows its part,
      # beside the program it resolves to, and must be that same program, so the name
      # never selects another one.
      compiler = File.realpath(compiler)
      found = HostPath.find_linker(linker, compiler: compiler, path: path)
      raise Error, "ERX_LLD names no executable linker: #{linker.inspect}" unless found
      installed = File.realpath(found)
      linker = File.join(File.dirname(installed), File.basename(found))
      unless File.file?(linker) && File.executable?(linker)
        raise Error, "ERX_LLD resolves to #{installed.inspect}, beside which is no executable #{linker.inspect}"
      end
      unless File.identical?(linker, installed)
        raise Error, "ERX_LLD resolves to #{installed.inspect}, but #{linker.inspect} beside it is not that program"
      end
      { compiler: compiler, linker: linker }.each { |variable, program| check_make_word(variable, program) }
      super(compiler: compiler, linker: linker)
    end

    # LLVM's binary tool of that name, beside clang: program('nm') is llvm-nm.
    def program(name) = File.join(File.dirname(compiler), "llvm-#{name}")

    # The settings of the kernel's build directory, for a checkout at root. The
    # kernel's Makeconf adds clang's --target from CROSS_COMPILE and takes an LLD
    # linker and a named CPP as given. Its ARFLAGS end in T, which recent GNU ar
    # reads as truncated names but llvm-ar as a thin archive, whose members the
    # link audit cannot read (ArchiveMember), and hold U, with which llvm-ar
    # records each member's time and owner; without both llvm-ar makes a normal,
    # deterministic archive. SHARED_FLAGS reaches every C, C++ and assembly compile.
    def kernel_settings(root:)
      { 'CC' => compiler, 'CXX' => clang('clang++'), 'CPP' => clang('clang-cpp'), 'LD' => linker,
        'ARFLAGS' => 'crs', **binary_tools, 'SHARED_FLAGS' => path_map(root) }
    end

    # Every program either build runs from the toolchain.
    def programs = [compiler, clang('clang++'), clang('clang-cpp'), linker, *binary_tools.values]

    # The settings of L4Re's build directory, for a checkout at root. CLANG names
    # clang's directory, from which mk takes clang, clang++ and clang-cpp with the
    # target flag. CCXX_FLAGS reaches every target compile.
    def user_settings(root:)
      { 'CLANG' => "#{File.dirname(compiler)}/", 'LD' => "#{linker} -m $(LD_EMULATION)", **binary_tools,
        'CCXX_FLAGS' => path_map(root) }
    end

    private

    # Flags, added to the inherited make system's own, that write every path under the
    # checkout at root into an object (debug information, __FILE__) relative to it, so
    # the Fiasco build's bytes do not depend on where the tree is checked out. The
    # inherited maps cover only each build's source and object directories, and the
    # kernel's only for GCC, while the erXos cores' headers are elsewhere under the
    # checkout. A root reached through a link is mapped by both its names: the compiler
    # names its working directory by the real one. Dependency files keep real paths.
    def path_map(root)
      check_make_word('checkout', root)
      [root, File.realpath(root)].uniq.map do |name|
        check_make_word('checkout', name)
        "-ffile-prefix-map=#{name}=."
      end
    end

    def clang(name) = File.join(File.dirname(compiler), name)

    def binary_tools = %w[AR NM OBJCOPY OBJDUMP RANLIB SIZE STRIP].to_h { |name| [name, program(name.downcase)] }
  end

  class FiascoToolchain
    # The target the inherited make systems give clang, as their CROSS_COMPILE.
    CROSS_COMPILE = 'aarch64-none-elf-'

    # The characters a toolchain path may have. Makeconf.local takes each path as
    # written into a make assignment, and the inherited make systems hand it to the
    # shell in their recipes, so only characters neither make nor the shell gives a
    # meaning are taken; an allow-list, matched on the bytes, so a new special
    # character or invalid UTF-8 is refused rather than passed on.
    MAKE_WORD = %r{\A[A-Za-z0-9._+@/-]+\z}

    # The toolchain the environment names.
    def self.from_environment(environment = ENV)
      new(compiler: environment.fetch('ERX_CLANG', ''), linker: environment.fetch('ERX_LLD', ''))
    end

    private

    def check_make_word(variable, program)
      return if program.b.match?(MAKE_WORD)

      raise Error, "the Fiasco #{variable} path #{program.inspect} has a character other than " \
                   'A-Z a-z 0-9 . _ + @ / -, which make cannot take'
    end
  end
end
