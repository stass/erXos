# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require_relative 'device_callers'
require_relative 'device_posters'
require_relative 'start_callers'

module Erx
  # The chokepoint "only erx_screen calls the display driver's flush and power requests"
  # (docs/design-display.md, "The display device" and Chokepoints): erx_screen is the one
  # sender of frames, so the screen image is read by the driver only while erx_screen,
  # which writes nothing during a frame, holds one out. Both requests are functions of the
  # behaviour module, erx_display:flush_request/3 and erx_display:power_request/2, which
  # build the one term a driver's handle_call/3 answers, so the rule is an exact one over
  # those two functions: outside erx_screen no Erlang source DeviceCallers reads names
  # either as a call target. The forms refused, as StartCallers refuses them for
  # start_session/2:
  #
  # * erx_display, or a quoted 'erx_display', with either name after a colon or a comma: a
  #   remote call, a fun, an apply's module and function, or a {Module, Function} pair;
  # * either name called through a module held in a variable or a macro, `M:flush_request(`
  #   or `?M:power_request(`, which no other module's function of that name excuses, since
  #   erx_display alone defines them;
  # * an apply whose function is either name, whatever its module;
  # * an import from erx_display, which would let a module call either by its bare name;
  # * a macro defined as the atom erx_display or as either name, which would hide the
  #   module or the function of a call.
  #
  # erx_display's own definitions and exports name no module and pass. The check reads the
  # sources with comments and strings removed, as StartCallers does, since a string calls
  # nothing and a doc string may name either function; over the whole text, so a call
  # split across lines is seen too. Like DevicePosters it catches a slip, not a message
  # built by hand and sent to the driver's process, nor a call whose function is a
  # variable or whose module is an expression, which the driver's review must.
  module DisplayDriverCallers
    SCREEN = 'erlang/apps/erx_display/src/erx_screen.erl'
    REQUESTS = %w[flush_request power_request].freeze

    ATOM = DevicePosters::ATOM
    MODULE = ATOM.call('erx_display')
    NAMES = "(?:#{REQUESTS.map { |name| ATOM.call(name) }.join('|')})".freeze
    CALLED = /
        #{MODULE}\s*[:,]\s*#{NAMES}
      | (?:#{StartCallers::INDIRECT})\s*:\s*#{NAMES}
      | #{ATOM.call('apply')}\s*\(\s*[^,()]+,\s*#{NAMES}
      | -\s*import\s*\(\s*#{MODULE}
      | -\s*define\s*\(\s*[^,()]+(?:\([^()]*\))?\s*,\s*(?:#{MODULE}|#{NAMES})\s*\)
    /x

    Violation = Data.define(:path, :line) do
      def to_s
        "chokepoint display-driver-callers: #{path}:#{line}: only #{SCREEN} may call " \
          'erx_display:flush_request/3 or erx_display:power_request/2'
      end
    end

    module_function

    def covers?(path) = DeviceCallers.covers?(path)

    # The violations among files, a map of path to source text, one per line.
    def violations(files)
      files.flat_map do |path, text|
        next [] if path == SCREEN || !covers?(path)

        DevicePosters.lines(StartCallers.code_without_strings(text), CALLED).uniq
                     .map { |line| Violation.new(path: path, line: line) }
      end
    end
  end
end
