# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'tmpdir'
require_relative 'a64_branch'
require_relative 'bounded_file'
require_relative 'stack_graph_input'

module Erx
  # The call graph and per-function frames the stack proof reads
  # (docs/design-kernel.md#stack-proof, docs/design-arch-aarch64.md#stack-proof),
  # extracted from AArch64 relocatable objects built by erXos's LLVM with
  # -fstack-usage. The depth, cycle and entry analysis consumes the Graph;
  # nothing here judges a depth.
  #
  # Each function's frame is the size clang wrote to the object's .su file.
  # Its edges come from decoding every instruction word of its body
  # (A64Branch) against the object's relocations:
  #
  # * a BL is a call only with an R_AARCH64_CALL26 relocation naming its
  #   target;
  # * a B with an R_AARCH64_JUMP26 relocation is a tail jump, which replaces
  #   the caller's frame; a musttail call is one at every optimization
  #   level, an ordinary tail call only when the optimizer made it;
  # * a BLR is an indirect call and a BR an indirect branch, recorded with
  #   their offsets for the analysis to match against the listed targets;
  # * every other branch, a B without a relocation or a conditional one,
  #   must land inside its own function.
  #
  # A call or jump relocation must name the start of a function or an
  # undefined global; one that names a function's middle, a call without its
  # relocation, a branch that leaves its function any other way, an unknown
  # instruction, a function without a frame record, a dynamic frame and an
  # instruction outside every function each refuse the whole object with a
  # StackGraphError naming the object, the function and the offset. So no
  # function silently becomes a leaf.
  #
  # A BL to a static function in the same section is resolved by the
  # assembler and keeps no relocation, and is refused like any call without
  # one; that refusal is what keeps the graph sound. Objects are compiled
  # with -ffunction-sections so that every call to another function crosses
  # a section and keeps its relocation, which lets ordinary code pass.
  #
  # Frames and tail jumps are read as the compiler made them: inline
  # assembly that moves the stack pointer or sets the link register itself
  # is not accounted for. Inline assembly is confined to listed functions by
  # its own chokepoint, and those functions must leave the stack pointer and
  # the link register to the compiler.
  module StackGraph
    MAX_INPUT_BYTES = 64 * 1024 * 1024
    TOOL_DEADLINE = 120
    BRANCH_RELOCATIONS = %w[R_AARCH64_CALL26 R_AARCH64_JUMP26 R_AARCH64_CONDBR19 R_AARCH64_TSTBR14].freeze

    # A function's identity: a global by its name alone (object nil), a
    # static function by its name and the object that defines it.
    Name = Data.define(:name, :object) do
      def global? = object.nil?
      def to_s = global? ? name : "#{name} (#{object})"
    end
    # offset is the byte offset of the instruction from its function's start.
    Site = Data.define(:offset, :target)
    IndirectSite = Data.define(:offset, :register)
    # location is the source position clang recorded with the frame.
    Function = Data.define(:id, :object, :location, :frame_bytes, :calls, :tail_jumps,
                           :indirect_calls, :indirect_branches)
    # functions maps each Name to its Function; externals lists the global
    # names called or jumped to that no input object defines, such as the
    # stopgap's erx_effect_* leaves.
    Graph = Data.define(:functions, :externals) do
      def fetch_function(id)
        functions.fetch(id) { raise StackGraphError, "stack graph has no function #{Terminal.escape(id)}" }
      end
    end
    Input = Data.define(:object, :stack_usage) do
      # clang writes the .su file beside the object it names with -o.
      def self.beside(object) = new(object: object, stack_usage: object.sub(/\.o\z/, '') + '.su')
    end
    Tools = Data.define(:objdump, :readobj) do
      # The LLVM binary tools installed with the given clang.
      def self.beside(compiler)
        directory = File.dirname(File.realpath(compiler))
        tools = %w[llvm-objdump llvm-readobj].map { |tool| File.join(directory, tool) }
        missing = tools.reject { |tool| File.file?(tool) && File.executable?(tool) }
        raise StackGraphError, "stack graph: missing #{missing.map { Terminal.escape(_1) }.join(', ')}" unless missing.empty?

        new(objdump: tools.first, readobj: tools.last)
      rescue SystemCallError => error
        raise StackGraphError, "stack graph: no compiler to find the LLVM tools beside: #{error.message}"
      end
    end
    # The three tool outputs of one object, as text.
    Unit = Data.define(:object, :listing, :disassembly, :stack_usage)

    module_function

    # Runs the LLVM tools over a private copy of each object, so both read
    # the same bytes, and builds the graph from their output.
    def extract(inputs:, tools:, runner:)
      raise StackGraphError, 'stack graph: no input objects' if inputs.empty?

      units = Dir.mktmpdir('erx-stack-graph-') do |scratch|
        inputs.each_with_index.map do |input, index|
          snapshot = File.join(scratch, "#{index}.o")
          File.binwrite(snapshot, BoundedFile.read(input.object, maximum: MAX_INPUT_BYTES))
          Unit.new(object: input.object,
                   listing: tool_output(runner, [tools.readobj, '--elf-output-style=JSON', '--file-headers',
                                                 '--sections', '--symbols', '--relocations', snapshot],
                                        name: 'stack-graph-readobj'),
                   disassembly: tool_output(runner, [tools.objdump, '-d', '-z', snapshot], name: 'stack-graph-objdump'),
                   stack_usage: BoundedFile.read(input.stack_usage, maximum: MAX_INPUT_BYTES))
        end
      end
      build(units)
    end

    # Pure: the graph of the given units, or a StackGraphError.
    def build(units)
      objects = units.map(&:object)
      duplicate = objects.tally.find { |_object, count| count > 1 }
      raise StackGraphError, "stack graph: #{Terminal.escape(duplicate.first)} is given twice" if duplicate

      link(units.flat_map { |unit| ObjectScan.new(unit).functions })
    end

    def tool_output(runner, argv, name:)
      environment = ENV.keys.to_h { |key| [key, nil] }.merge('PATH' => ENV.fetch('PATH'), 'LC_ALL' => 'C')
      record = runner.run(argv, name: name, deadline: TOOL_DEADLINE, env: environment,
                                output_limit: MAX_INPUT_BYTES)
      # Output that reaches the file-size cap is a refusal, never a short graph.
      BoundedFile.read(record.fetch('log'), maximum: MAX_INPUT_BYTES - 1)
    end

    def link(functions)
      table = functions.each_with_object({}) do |function, defined|
        if defined.key?(function.id)
          raise StackGraphError, "stack graph: #{Terminal.escape(function.id)} is defined in both " \
                                 "#{Terminal.escape(defined[function.id].object)} and #{Terminal.escape(function.object)}"
        end
        defined[function.id] = function
      end.freeze
      externals = functions.flat_map { |function| function.calls + function.tail_jumps }
                           .map(&:target).reject { |target| table.key?(target) }.uniq.sort_by(&:name)
      Graph.new(functions: table, externals: externals.freeze)
    end

    private_class_method :tool_output, :link

    # The functions of one object. It owns the object's parsed listing,
    # disassembly and frames, and checks first that the symbol table and
    # the disassembly describe the same bodies, so that scanning a function
    # reads every one of its instructions and nothing else.
    class ObjectScan
      def initialize(unit)
        @object = unit.object
        @listing = StackGraphInput.listing(unit.listing, object: @object)
        @frames = StackGraphInput.stack_usage(unit.stack_usage, object: @object)
        @symbols = function_symbols
        @starts = @symbols.to_h { |symbol| [[symbol.section, symbol.value], symbol] }
        @code = checked_code(StackGraphInput.disassembly(unit.disassembly, object: @object))
      end

      def functions
        unframed = @frames.keys - @symbols.map(&:name)
        refuse("frame record #{unframed.first} names no function of the object") unless unframed.empty?
        @symbols.map { |symbol| function(symbol) }
      end

      private

      # The kinds a function's last instruction may have: each leaves the
      # function, so no path runs off its end into whatever the link places
      # after it. A call is allowed for the call of a noreturn function
      # that clang leaves last.
      ENDINGS = %i[return jump indirect_jump trap call].freeze
      # The Function field each edge-making kind of instruction fills.
      EDGE_FIELDS = { call: :calls, tail_jump: :tail_jumps, indirect_call: :indirect_calls,
                      indirect_jump: :indirect_branches }.freeze

      def function(symbol)
        frame = @frames.fetch(symbol.name) { refuse_at(symbol, 0, 'no recorded frame size') }
        decoded = body(symbol).map { |offset, instruction| [offset, decoded_instruction(symbol, offset, instruction)] }
        last_offset, last = decoded.last
        refuse_at(symbol, last_offset, "body ends in a #{last.kind} instruction") unless ENDINGS.include?(last.kind)
        sites = decoded.filter_map { |offset, instruction| edge(symbol, offset, instruction) }
                       .group_by(&:first).transform_values { |pairs| pairs.map(&:last).freeze }
        Function.new(id: name_of(symbol), object: @object, location: frame.location, frame_bytes: frame.bytes,
                     **EDGE_FIELDS.to_h { |kind, field| [field, sites.fetch(kind, [].freeze)] })
      end

      # [offset from the function's start, instruction] for every word of
      # the body. section_code has checked that objdump listed each one, so
      # the fetches cannot fail.
      def body(symbol)
        (symbol.value...(symbol.value + symbol.size)).step(4).map do |address|
          [address - symbol.value, @code.fetch(symbol.section).fetch(address)]
        end
      end

      def decoded_instruction(symbol, offset, instruction)
        decoded = A64Branch.decode(instruction.word)
        return decoded if A64Branch.mnemonic_agrees?(decoded, instruction.mnemonic)

        refuse_at(symbol, offset, format('unknown instruction %08x (%s)', instruction.word,
                                         Terminal.escape(instruction.mnemonic)))
      end

      # The edge one decoded instruction contributes, as [EDGE_FIELDS key,
      # site], or nil for an instruction that adds none: an ordinary one, a
      # return, a trap, or a branch that stays inside its function.
      def edge(symbol, offset, decoded)
        relocation = @listing.relocations[[symbol.section, symbol.value + offset]]
        check_relocation(symbol, offset, decoded, relocation)
        case decoded.kind
        when :call then [:call, Site.new(offset: offset, target: target(symbol, offset, relocation))]
        when :jump
          return [:tail_jump, Site.new(offset: offset, target: target(symbol, offset, relocation))] if relocation

          check_inside(symbol, offset, decoded.delta)
          nil
        when :conditional
          check_inside(symbol, offset, decoded.delta)
          nil
        when :indirect_call, :indirect_jump
          [decoded.kind, IndirectSite.new(offset: offset, register: decoded.register)]
        end
      end

      # A BL needs its CALL26 and a B may carry only a JUMP26; no other
      # control-flow instruction carries a relocation, and no other
      # instruction carries a branch relocation.
      def check_relocation(symbol, offset, decoded, relocation)
        type = relocation&.type
        if decoded.kind == :call && type.nil?
          refuse_at(symbol, offset, 'call without a relocation naming its target')
        end
        allowed = case decoded.kind
                  when :call then type == 'R_AARCH64_CALL26'
                  when :jump then type.nil? || type == 'R_AARCH64_JUMP26'
                  when :plain then !BRANCH_RELOCATIONS.include?(type)
                  else type.nil?
                  end
        refuse_at(symbol, offset, "#{decoded.kind} instruction with relocation #{Terminal.escape(type)}") unless allowed
      end

      # The function a call or jump relocation names: the start of a
      # function of this object, or an undefined global that another object
      # or the analysis's declared leaves account for. A section symbol's
      # value is zero in a relocatable object, so value plus addend is the
      # target's offset in the symbol's section for both defined forms.
      def target(symbol, offset, relocation)
        named = relocation.symbol
        if named.defined? && %w[Section Function].include?(named.type)
          function_at(symbol, offset, section: named.section, address: named.value + relocation.addend)
        elsif named.section == :undefined && named.binding == 'Global' && StackGraphInput::IDENTIFIER.match?(named.name)
          refuse_at(symbol, offset, "branch into the middle of #{named.name}") unless relocation.addend.zero?
          Name.new(name: named.name, object: nil)
        else
          refuse_at(symbol, offset, "branch target #{Terminal.escape(named.name)} is not a function")
        end
      end

      def function_at(symbol, offset, section:, address:)
        start = @starts[[section, address]]
        return name_of(start) if start

        inside = @symbols.find { |candidate| candidate.section == section && covers?(candidate, address) }
        if inside
          refuse_at(symbol, offset, "branch into the middle of #{inside.name}+0x#{(address - inside.value).to_s(16)}")
        end
        refuse_at(symbol, offset, "branch to #{section_name(section)}+0x#{address.to_s(16)}, where no function starts")
      end

      def check_inside(symbol, offset, delta)
        return if (0...symbol.size).cover?(offset + delta)

        refuse_at(symbol, offset, 'branch leaves its function without a call or jump relocation')
      end

      # Every function symbol, validated: a local or global C identifier
      # whose body lies in an executable section and overlaps no other.
      def function_symbols
        symbols = @listing.symbols.select { |symbol| symbol.type == 'Function' }
        symbols.each { |symbol| check_function_symbol(symbol) }
        symbols.group_by(&:section).each_value do |group|
          group.sort_by(&:value).each_cons(2) do |before, after|
            refuse("#{after.name} overlaps #{before.name}") if after.value < before.value + before.size
          end
        end
        symbols.sort_by { |symbol| [symbol.section, symbol.value] }.freeze
      end

      def check_function_symbol(symbol)
        refuse("function symbol #{symbol.index} has an unreadable name") unless StackGraphInput::IDENTIFIER.match?(symbol.name)
        unless %w[Local Global].include?(symbol.binding)
          refuse("#{symbol.name}: #{Terminal.escape(symbol.binding)} binding: the link may choose another definition")
        end
        section = @listing.sections[symbol.section] if symbol.defined?
        refuse("#{symbol.name} is not defined in an executable section") unless section&.executable
        unless symbol.size.positive? && (symbol.value % 4).zero? && (symbol.size % 4).zero? &&
               symbol.value + symbol.size <= section.size
          refuse("#{symbol.name} has no whole-instruction body inside #{section.name}")
        end
      end

      # The instructions of each executable section by offset. objdump names
      # sections, not indices, so the executable sections' names must be
      # unique and objdump must disassemble no other section; section_code
      # then checks that the functions' bodies cover each section's
      # instructions exactly.
      def checked_code(disassembly)
        executable = @listing.sections.each_value.select(&:executable)
        names = executable.map(&:name)
        refuse("two executable sections are named #{names.tally.find { _2 > 1 }.first}") unless names.uniq == names
        stray = disassembly.keys - names
        refuse("objdump disassembled #{stray.first}, which is no executable section") unless stray.empty?
        executable.to_h { |section| [section.index, section_code(section, disassembly.fetch(section.name, []))] }.freeze
      end

      def section_code(section, listed)
        code = listed.to_h { |instruction| [instruction.offset, instruction] }
        refuse("objdump lists an offset of #{section.name} twice") unless code.size == listed.size
        bodies = @symbols.select { |symbol| symbol.section == section.index }
        bodies.each do |symbol|
          (symbol.value...(symbol.value + symbol.size)).step(4) do |address|
            refuse_at(symbol, address - symbol.value, 'objdump lists no instruction here') unless code.key?(address)
          end
        end
        stray = code.keys.find { |address| bodies.none? { |symbol| covers?(symbol, address) } }
        refuse("#{section.name}+0x#{stray.to_s(16)}: instruction outside every function") if stray
        code.freeze
      end

      def covers?(symbol, address) = address >= symbol.value && address < symbol.value + symbol.size

      def name_of(symbol) = Name.new(name: symbol.name, object: symbol.binding == 'Local' ? @object : nil)

      def section_name(index) = @listing.sections[index]&.name || "section #{index}"

      def refuse(message) = StackGraphInput.refuse(@object, message)

      def refuse_at(symbol, offset, message)
        refuse("#{symbol.name}+0x#{offset.to_s(16)}: #{message}")
      end
    end
  end
end
