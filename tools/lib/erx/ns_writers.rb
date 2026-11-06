# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require_relative 'device_callers'

module Erx
  # The chokepoints of the namespace's writers (docs/design.md, "Chokepoint checks";
  # docs/design-files.md, "Building, binding and mounting" and "Erlang clients"):
  # only erx_ns's process writes the namespace's persistent term, and only
  # prim_file:set_cwd/1 calls the NIF that stores the working directory, so a
  # resolution reads one table one writer made and one working directory set_cwd
  # checked.
  #
  # The check reads the Erlang sources that can enter a release, as DeviceCallers
  # does, with comments removed and strings kept. ns-table-writer refuses a
  # persistent_term:put or erase of the key erx_ns outside erx_ns.erl. cwd-writer
  # also refuses a call of prim_file's bridge to its NIF's table, erx_ns_mount, erx_ns_bind
  # or erx_ns_unmount, outside erx_ns.erl and prim_file.erl, so the NIF's table that
  # today's resolution reads changes only with the term. cwd-writer
  # refuses the name erx_set_cwd_nif anywhere but in prim_file.erl's set_cwd
  # function, the NIF's own stub, and a Name/1 in an attribute such as -nifs. Like the
  # other text rules it catches a slip, not a key or a call built from pieces.
  module NsWriters
    SCOPE = DeviceCallers::SCOPE
    GLOB_FLAGS = File::FNM_PATHNAME | File::FNM_EXTGLOB
    WRITER = 'erlang/apps/erx/src/erx_ns.erl'
    PRIM_FILE = 'otp/erts/preloaded/src/prim_file.erl'
    TABLE_WRITE = /persistent_term\s*:\s*(?:put|erase)\s*\(\s*'?erx_ns'?(?![A-Za-z0-9_@])/
    NIF_TABLE_WRITE = /(?<![A-Za-z0-9_@])'?erx_ns_(?:mount|bind|unmount)'?(?![A-Za-z0-9_@])/
    CWD_NIF = /(?<![A-Za-z0-9_@])'?erx_set_cwd_nif'?(?![A-Za-z0-9_@])(?<arity>\s*\/\s*1)?/
    # A form starts at the first column: an attribute with -, a function clause with its
    # name.
    FORM = /\A(?:(?<attribute>-)|'?(?<function>[a-z][A-Za-z0-9_@]*)'?\s*\()/
    CWD_SITES = %w[set_cwd erx_set_cwd_nif].freeze

    Violation = Data.define(:rule, :path, :line, :detail) do
      def to_s = "chokepoint #{rule}: #{path}:#{line}: #{detail}"
    end

    module_function

    def covers?(path) = SCOPE.any? { |glob| File.fnmatch?(glob, path, GLOB_FLAGS) }

    # The violations among files, a map of path to source text.
    def violations(files)
      files.select { |path, _| covers?(path) }.flat_map do |path, text|
        code = DeviceCallers.code(text)
        table_writes(path, code) + cwd_writes(path, code)
      end
    end

    def table_writes(path, code)
      return [] if path == WRITER

      writes = code.to_enum(:scan, TABLE_WRITE).map { Regexp.last_match.begin(0) }
      writes += code.to_enum(:scan, NIF_TABLE_WRITE).map { Regexp.last_match.begin(0) } unless path == PRIM_FILE
      writes.sort.map do |offset|
        Violation.new(rule: 'ns-table-writer', path: path, line: code[0, offset].count("\n") + 1,
                      detail: "only #{WRITER} writes the namespace's persistent term erx_ns and the NIF's table")
      end
    end

    # Each line's form is read from the code with its strings blanked, so a string
    # holding a line that looks like a form starts none.
    def cwd_writes(path, code)
      forms = forms_of(blanked(code))
      code.each_line.with_index.flat_map do |line, index|
        line.to_enum(:scan, CWD_NIF).filter_map do
          next if path == PRIM_FILE && allowed?(forms[index], Regexp.last_match[:arity])

          Violation.new(rule: 'cwd-writer', path: path, line: index + 1,
                        detail: 'only prim_file:set_cwd/1 calls erx_set_cwd_nif')
        end
      end
    end

    def allowed?(form, arity) = CWD_SITES.include?(form) || (form == :attribute && arity)

    # The form each line belongs to: :attribute, a function's name, or nil before any.
    def forms_of(skeleton)
      skeleton.each_line.each_with_object([]) do |line, forms|
        found = FORM.match(line)
        forms << if found.nil? then forms.last
                 elsif found[:attribute] then :attribute
                 else found[:function]
                 end
      end
    end

    # The code with every string, atom in quotes and character blanked, lines kept.
    def blanked(code)
      code.gsub(DeviceCallers::LEXEME) { Regexp.last_match(0).gsub(/[^\n]/, ' ') }
    end
  end
end
