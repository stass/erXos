# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require_relative 'error'

module Erx
  # The interpreter image, the runtime image the system domain runs, holds no BeamAsm, no
  # asmjit, no libc++ and no libc++abi, so no code generator and no C++ joins the trusted
  # base (docs/design-runtime.md, R10). The build check reads every symbol the linked
  # program keeps, defined or referenced, through llvm-nm, and fails on any C++ name.
  # NativeRoot runs it on the system's root task, which links ERTS in Phase 1.
  module InterpreterImage
    # The property is "no C++", so the last family refuses every C++ name: every
    # Itanium-mangled one (_Z), libc++abi's typeinfo classes, and the C++ runtime's entry
    # points, of which musl defines __cxa_atexit and __cxa_finalize for C's atexit. The
    # families before it only name what was found: BeamAsm's C entry points and assemblers,
    # asmjit's namespace and libc++'s inline namespaces (std::__1, Android's std::__ndk1).
    # A name goes to the first family that matches it.
    FOREIGN = {
      'BeamAsm' => /\Abeamasm_|Beam(?:Global|Module)?Assembler|beam_jit_/,
      'asmjit' => /asmjit/i,
      'libc++' => /St3__[0-9]|St6__ndk1/,
      'C++' => /\A_Z|__cxxabiv1|\A__gxx_personality|\A__dynamic_cast\z|\A__cxa_(?!atexit\z|finalize\z)/
    }.freeze
    # ERTS's entry, which every interpreter image defines. A listing without it is of a
    # stripped or wrong program, which would otherwise pass as clean.
    WITNESS = 'erl_start'
    # How many names of a family the refusal shows before it gives the count.
    SHOWN = 5
    NM_DEADLINE = 120

    module_function

    # Of names, those of each foreign family, sorted, keyed by the family; families with
    # none are left out, so an empty hash is a clean image.
    def foreign_symbols(names)
      names.uniq.sort.each_with_object({}) do |name, found|
        family = FOREIGN.find { |_family, pattern| pattern.match?(name) }&.first
        (found[family] ||= []) << name if family
      end
    end

    # Raises unless program lists ERTS's entry and no foreign symbol.
    def check(program:, nm:, runner:)
      names = symbol_names(program: program, nm: nm, runner: runner)
      raise Error, "#{program} lists no #{WITNESS}, so its symbols cannot show what it links" unless names.include?(WITNESS)

      found = foreign_symbols(names)
      return if found.empty?

      listed = found.map do |family, symbols|
        more = symbols.size > SHOWN ? " and #{symbols.size - SHOWN} more" : ''
        "#{family}: #{symbols.first(SHOWN).join(' ')}#{more}"
      end
      raise Error, "the interpreter image #{program} links what the system domain must not hold: #{listed.join('; ')}"
    end

    # One name per line. The Runner's log holds llvm-nm's warnings too, which carry a
    # space, as no symbol name does, so they are dropped.
    def symbol_names(program:, nm:, runner:)
      record = runner.run([nm, '--format=just-symbols', program], name: 'interpreter-image-nm', deadline: NM_DEADLINE)
      File.binread(record.fetch('log')).each_line(chomp: true).grep(/\A\S+\z/)
    end
    private_class_method :symbol_names
  end
end
