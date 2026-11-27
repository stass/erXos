# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'set'
require_relative 'error'

module Erx
  # The preloaded modules' one rule: a preloaded module calls only what the emulator
  # holds before the boot loads its first module, a BIF or a function of a preloaded
  # module. The boot's first reads (init, erl_prim_loader, prim_file, erx_path,
  # erx_facets) run before any module is loaded, so a call that leaves that set, such as
  # lists:sort/1 or maps:to_list/1, which are Erlang functions of stdlib, kills the
  # boot with "cannot get bootfile" when the path reaches it early, and holds only by
  # timing when it does not.
  #
  # The rule reads what the compiler made, each preloaded beam's import table (its ImpT
  # chunk), so it sees every direct remote call with its arity, a call the compiler wrote
  # included; a literal external fun (fun M:F/A, kept in the literal table) and a call
  # through a variable module (erlang:apply/3) it does not see. The allowed set is
  # derived: the preload list is the preloaded Makefile's PRE_LOADED_MODULES, which the
  # emulator's PRELOAD_BEAM repeats (erts/emulator/Makefile.in), and the BIFs are the
  # lines of the emulator's bif.tab. The runtime build checks the beams it compiled,
  # before the emulator embeds them (Runtime#build_emulator).
  #
  # Stock OTP's preloaded modules already call outside the set (init calls into kernel
  # and stdlib once the boot has loaded them), so the rule binds the modules erXos wrote,
  # those named erx_*, whose calls no upstream code relies on. A call of theirs that
  # leaves the set is refused unless AFTER_BOOT lists it with the reason its path runs
  # only once the boot has loaded the callee's module, so a new one is refused until it
  # is reviewed.
  module PreloadCalls
    class Refused < Error; end

    MAKEFILE = 'erts/preloaded/src/Makefile'
    BIF_TABLE = 'erts/emulator/beam/bif.tab'
    BOUND = /\Aerx_/

    # The calls of erXos's preloaded modules that leave the set, reviewed: each runs only
    # on a path the boot does not take before it loads the callee's module.
    AFTER_BOOT = {
      # await/3 and changed/1, a waiter's request to the connection agent, which runs
      # once the domain's applications are started, never in a path's resolution.
      'erx_facets' => %w[gen:receive_response/2 gen:send_request/3],
      # A program's start, which a session asks once the boot is done.
      'erx_program' => %w[lists:flatmap/2 lists:keysort/2 lists:partition/2 lists:seq/2 lists:seq/3 lists:sort/1
                          maps:map/2 maps:with/2],
      # The grammar's builders (sort_list/5), which only a program's start calls.
      'erx_prog_grammar' => %w[lists:sort/1]
    }.transform_values { |calls| calls.to_set.freeze }.freeze

    # A remote call of a module's import table.
    Import = Data.define(:module_name, :function, :arity) do
      def to_s = "#{module_name}:#{function}/#{arity}"
    end

    module_function

    # Refuses, naming each, every call of a beam under ebin of a preloaded module erXos
    # wrote that is no BIF and leaves the preloaded modules. otp is the root of the OTP
    # sources the beams were compiled from.
    def enforce!(otp:, ebin:)
      preloaded = modules(File.read(File.join(otp, MAKEFILE)))
      bifs = bifs(File.read(File.join(otp, BIF_TABLE)))
      found = preloaded.grep(BOUND).flat_map do |name|
        allowed = bifs | AFTER_BOOT.fetch(name, Set[])
        refused(imports(File.binread(File.join(ebin, "#{name}.beam"))), preloaded: preloaded, bifs: allowed)
          .map { |import| "#{name} calls #{import}" }
      end
      return if found.empty?

      raise Refused, "a preloaded module calls what is neither a BIF nor a preloaded module's function, so the " \
                     "boot dies with \"cannot get bootfile\" when its path reaches the call before that module " \
                     "loads:\n  #{found.join("\n  ")}"
    end

    # The imports a preloaded module may not make: those of a module outside the preload
    # list that no line of bif.tab names.
    def refused(imports, preloaded:, bifs:)
      imports.reject { |import| preloaded.include?(import.module_name) || bifs.include?(import.to_s) }
    end

    # The preload list, PRE_LOADED_ERL_MODULES and PRE_LOADED_BEAM_MODULES of the
    # preloaded Makefile, each a variable of names continued across lines.
    def modules(makefile)
      makefile.gsub("\\\n", ' ')
              .scan(/^PRE_LOADED_(?:ERL|BEAM)_MODULES\s*=(.*)$/)
              .flat_map { |(names)| names.split }
              .to_set
              .tap { |names| raise Refused, "#{MAKEFILE} names no preloaded module" if names.empty? }
    end

    # Each BIF of bif.tab as module:function/arity, its quotes dropped, as Import#to_s spells it.
    def bifs(table)
      table.scan(%r{^[uh]?bif\s+'?([a-z_]+)'?:'?([^/'\s]+)'?/(\d+)}).to_set { |module_name, function, arity| "#{module_name}:#{function}/#{arity}" }
    end

    # The import table of a beam, its ImpT chunk read through its AtU8 atoms.
    def imports(beam)
      chunks = chunks(beam)
      atoms = atoms(chunks.fetch('AtU8') { raise Refused, 'a preloaded beam has no AtU8 chunk' })
      table = chunks.fetch('ImpT') { raise Refused, 'a preloaded beam has no ImpT chunk' }
      count = table.unpack1('N')
      table.byteslice(4, count * 12).unpack('N*').each_slice(3).map do |module_index, function_index, arity|
        Import.new(module_name: atoms.fetch(module_index - 1), function: atoms.fetch(function_index - 1), arity: arity)
      end
    end

    # A beam's chunks by id: the IFF form FOR1, its size, BEAM, then each chunk's id,
    # size and data, padded to four bytes.
    def chunks(beam)
      form, size, kind = beam.unpack('a4Na4')
      raise Refused, 'a preloaded beam is not a BEAM file' unless form == 'FOR1' && kind == 'BEAM' && size + 8 <= beam.bytesize

      offset = 12
      found = {}
      while offset + 8 <= size + 8
        id, length = beam.byteslice(offset, 8).unpack('a4N')
        found[id] = beam.byteslice(offset + 8, length)
        offset += 8 + ((length + 3) & ~3)
      end
      found
    end

    # The atoms of an AtU8 chunk: a count, negative when each length is in the compact
    # term encoding OTP 28's compiler writes (lib/compiler/src/beam_asm.erl,
    # build_atom_table/2), else a byte, then each length and its UTF-8 text.
    def atoms(chunk)
      count = chunk.unpack1('l>')
      offset = 4
      Array.new(count.abs) do
        length, offset = count.negative? ? compact_length(chunk, offset) : [chunk.getbyte(offset), offset + 1]
        text = chunk.byteslice(offset, length).force_encoding(Encoding::UTF_8)
        offset += length
        text
      end
    end

    # An atom's length in the compact encoding with tag u: one byte for less than 16,
    # two for less than 2048, which no atom reaches (atoms are at most 255 characters).
    def compact_length(chunk, offset)
      first = chunk.getbyte(offset)
      return [first >> 4, offset + 1] if first.nobits?(0b1000)
      raise Refused, 'a preloaded beam has an atom length longer than two bytes' if first.allbits?(0b10000)

      [((first & 0b11100000) << 3) | chunk.getbyte(offset + 1), offset + 2]
    end
  end
end
