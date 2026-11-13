# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require_relative 'device_callers'
require_relative 'device_posters'

module Erx
  # The chokepoint "only the connection agent maps a pixel area" (docs/design-display.md,
  # "The pixel area" and "Chokepoints"): erx_area:map/4 is called only by erx_connections,
  # the domain's connection agent, which counts the mapping and answers that the
  # connection is unmapped only after the area's destructor has run. A mapping made by any
  # other process is one the agent does not wait for, and on the stopgap, whose map path
  # checks no rights (docs/design-stopgap.md), the agent's choice of read for the display
  # is also what keeps the display's mapping read-only.
  #
  # The rule is a closed allowance rather than a list of forbidden call shapes: outside
  # erx_area and erx_connections, the atom erx_area appears only as the module of
  # erx_area:open/1 (a call or a fun) and of its type erx_area:area(). Every other
  # mention is refused: erx_area:map/4 as a call or a fun, quoted or not; erx_area as an
  # apply's module, an import's or a macro's body; and erx_area inside a list, tuple or
  # map literal or a string, the forms a caller could hand to apply/3 or list_to_atom/1.
  #
  # The check reads the Erlang sources DeviceCallers reads, with comments removed and
  # strings kept, over the whole text, so a call split across lines is seen too. Doc
  # strings are strings: a -doc that names erx_area:map/4 is refused too, and says
  # "the connection agent's mapping" instead. Tests,
  # under test/, are outside the scope and map stand-in areas freely. Like PipeMakers it
  # catches a slip, not a module that holds erx_area in a variable built at run time.
  module AreaMappers
    AGENT = 'erlang/apps/erx/src/erx_connections.erl'
    SITES = ['erlang/apps/erx/src/erx_area.erl', AGENT].freeze
    MODULE = DevicePosters::ATOM.call('erx_area')
    # open/1, which hands a held area out, and area(), the type a -spec names.
    ALLOWED = %w[open area].freeze
    # Scanned left to right: at each place the allowed form is tried first, so the atom
    # matches as a violation only where it is not the module of open or area.
    FORMS = /
        (?<allowed>#{MODULE}\s*:\s*(?:#{ALLOWED.map { |name| DevicePosters::ATOM.call(name) }.join('|')}))
      | (?<named>#{MODULE})
    /x

    Violation = Data.define(:path, :line) do
      def to_s = "chokepoint area-mappers: #{path}:#{line}: only #{AGENT} may call erx_area:map/4; " \
                 'elsewhere erx_area is named only as erx_area:open and erx_area:area'
    end

    module_function

    def covers?(path) = DeviceCallers.covers?(path)

    # The violations among files, a map of path to source text.
    def violations(files)
      files.flat_map do |path, text|
        next [] if !covers?(path) || SITES.include?(path)

        code = DeviceCallers.code(text)
        code.to_enum(:scan, FORMS).filter_map do
          match = Regexp.last_match
          Violation.new(path: path, line: code[0, match.begin(0)].count("\n") + 1) if match[:named]
        end
      end
    end
  end
end
