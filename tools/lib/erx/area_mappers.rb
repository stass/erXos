# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require_relative 'device_callers'
require_relative 'device_posters'

module Erx
  # The chokepoint over who maps a pixel area (docs/design-display.md, "The pixel area"
  # and "Chokepoints"). An area is mapped in two places: into the runtime by the
  # connection agent, erx_connections, through erx_area:map/4, and into a program's
  # sub-space from a lease that erx_pixels, the one lender, made with erx_area:lend/5. So
  # every runtime mapping is one the agent waits for before it answers that the connection
  # is unmapped, the display's is the read-only one the agent asked for, and a program maps
  # only a whole range of its handler's.
  #
  # The Erlang half is a closed allowance rather than a list of forbidden call shapes:
  # outside erx_area and erx_connections, the atom erx_area appears only as the module of
  # erx_area:open/1 (a call or a fun) and of its type erx_area:area(), and in erx_pixels
  # also as the module of lend/5, unlend/1 and zero/3. Every other mention is refused:
  # map/4, or lend/5, unlend/1 or zero/3 outside erx_pixels, as a call or a fun, quoted or
  # not; erx_area as
  # an apply's module, an import's or a macro's body; and erx_area inside a list, tuple or
  # map literal or a string, the forms a caller could hand to apply/3 or list_to_atom/1.
  # It reads the Erlang sources DeviceCallers reads, with comments removed and strings
  # kept, over the whole text, so a call split across lines is seen too, and a -doc that
  # names erx_area:map/4 is refused as any string is. Tests, under test/, are outside the
  # scope. Like PipeCallers it catches a slip, not a module that holds erx_area in a
  # variable built at run time.
  #
  # The C half reads every C and C++ file of otp/erts/emulator with string and character
  # literals and comments blanked in one left-to-right pass, so a literal holding "/*"
  # hides no code and a comment holding a quote hides none either. The lease's driver
  # functions, erx_area_lease_take, erx_area_lease_map and erx_area_lease_return, are
  # named only in erx_area.h, which declares them, erx_area_nif.c, which defines them, and
  # erx_program_drv.c, the program driver that calls them. erx_vm_map is named only as a
  # call, directly followed by its "(", so no pointer, macro alias or parenthesized name
  # reaches it unseen. A call whose first argument, the space, is not ERX_CAP_SELF appears
  # exactly once in erx_area_nif.c, inside the body of erx_area_lease_map, which runs from
  # the line "erx_area_lease_map(" (the style guide puts a definition's name at the start
  # of its line) to the first closing brace at the start of a line, and nowhere else; so
  # no other mapper maps into a program whatever slot it is handed.
  module AreaMappers
    AGENT = 'erlang/apps/erx/src/erx_connections.erl'
    LENDER = 'erlang/apps/erx_display/src/erx_pixels.erl'
    SITES = ['erlang/apps/erx/src/erx_area.erl', AGENT].freeze
    MODULE = DevicePosters::ATOM.call('erx_area')
    # open/1, which hands a held area out, and area(), the type a -spec names.
    ALLOWED = %w[open area].freeze
    LENDING = %w[lend unlend zero].freeze

    # Scanned left to right: at each place the allowed form is tried first, so the atom
    # matches as a violation only where it is not the module of an allowed function.
    def self.forms(allowed)
      names = allowed.map { |name| DevicePosters::ATOM.call(name) }.join('|')
      /(?<allowed>#{MODULE}\s*:\s*(?:#{names})) | (?<named>#{MODULE})/x
    end
    FORMS = forms(ALLOWED)
    LENDER_FORMS = forms(ALLOWED + LENDING)

    C_SCOPE = 'otp/erts/emulator/**/*.{c,h,cpp}'
    NIF = 'otp/erts/emulator/nifs/erxos/erx_area_nif.c'
    DRIVER = 'otp/erts/emulator/sys/erxos/erx_program_drv.c'
    LEASE_SITES = ['otp/erts/emulator/nifs/erxos/erx_area.h', NIF, DRIVER].freeze
    LEASE_CALL = /\berx_area_lease_(?:take|map|return)\b/
    # erx_vm_map named other than as a call.
    MAP_NAME = /\berx_vm_map\b(?!\()/
    # An erx_vm_map whose space is anything but ERX_CAP_SELF.
    FOREIGN_MAP = /\berx_vm_map\(\s*(?!ERX_CAP_SELF\s*,)/
    FOREIGN_MAPPER = 'erx_area_lease_map'
    # The lease mapper's body: from its definition's first line to the first closing brace
    # at the start of a line.
    MAPPER_BODY = /^#{FOREIGN_MAPPER}\(.*?^\}/m
    # What is blanked before scanning, found in one pass so each starts outside the others.
    C_LITERAL_OR_COMMENT = %r{"(?:\\.|[^"\\\n])*"|'(?:\\.|[^'\\\n])*'|/\*.*?\*/|//[^\n]*}m

    Violation = Data.define(:path, :line) do
      def to_s = "chokepoint area-mappers: #{path}:#{line}: only #{AGENT} may call erx_area:map/4 and only " \
                 "#{LENDER} erx_area:lend/5, unlend/1 and zero/3; elsewhere erx_area is named only as " \
                 'erx_area:open and erx_area:area'
    end

    CViolation = Data.define(:path, :line, :what) do
      def to_s = "chokepoint area-mappers: #{path}:#{line}: #{what}"
    end

    module_function

    def covers?(path) = DeviceCallers.covers?(path) || c_file?(path)

    def c_file?(path) = File.fnmatch?(C_SCOPE, path, File::FNM_PATHNAME | File::FNM_EXTGLOB)

    # The violations among files, a map of path to source text.
    def violations(files)
      files.flat_map do |path, text|
        if c_file?(path)
          c_violations(path, text)
        elsif DeviceCallers.covers?(path) && !SITES.include?(path)
          erlang_violations(path, text)
        else
          []
        end
      end
    end

    def erlang_violations(path, text)
      code = DeviceCallers.code(text)
      forms = path == LENDER ? LENDER_FORMS : FORMS
      code.to_enum(:scan, forms).filter_map do
        match = Regexp.last_match
        Violation.new(path: path, line: line_at(code, match.begin(0))) if match[:named]
      end
    end

    # Literals and comments are blanked to their newlines, so line numbers stay those of the file.
    def c_violations(path, text)
      code = text.b.gsub(C_LITERAL_OR_COMMENT) { |blanked| blanked.gsub(/[^\n]/, ' ') }
      lease_calls = LEASE_SITES.include?(path) ? [] : offsets(code, LEASE_CALL).map do |offset|
        CViolation.new(path: path, line: line_at(code, offset),
                       what: "only #{DRIVER} calls the lease's driver functions")
      end
      names = offsets(code, MAP_NAME).map do |offset|
        CViolation.new(path: path, line: line_at(code, offset), what: 'erx_vm_map is named only as a call')
      end
      lease_calls + names + foreign_maps(path, code)
    end

    # Every foreign erx_vm_map but one: the first inside the lease mapper's body in
    # erx_area_nif.c. That file without one is refused at its first line.
    def foreign_maps(path, code)
      sites = offsets(code, FOREIGN_MAP)
      body = code.match(MAPPER_BODY) if path == NIF
      kept = body ? sites.select { |offset| offset.between?(body.begin(0), body.end(0)) }.first(1) : []
      refused = (sites - kept).map do |offset|
        CViolation.new(path: path, line: line_at(code, offset),
                       what: "only #{FOREIGN_MAPPER} maps into a space other than ERX_CAP_SELF, and once")
      end
      return refused unless path == NIF && kept.empty?

      refused + [CViolation.new(path: path, line: 1, what: "#{FOREIGN_MAPPER} maps no lease into a program's space")]
    end

    def offsets(code, pattern) = code.to_enum(:scan, pattern).map { Regexp.last_match.begin(0) }

    def line_at(code, offset) = code[0, offset].count("\n") + 1
  end
end
