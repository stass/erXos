# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require_relative 'device_callers'
require_relative 'device_posters'

module Erx
  # The chokepoint "only the pipe server makes a pipe's objects" (docs/design-pipes.md,
  # invariant PI1): a pipe's lock, its lanes and its ends' bells are made only by
  # erx_pipe_nif's make_lock/0, make_lane/1 and make_bell/3, and erx_pipe_srv, the session's
  # pipe server, is the one module that calls them, each for a step its pure core
  # (erx_pipe) decided. The rule is therefore that no Erlang source but erx_pipe_srv and
  # the NIF's own module names one of the three as a call target.
  #
  # The check reads the Erlang sources DeviceCallers reads, with comments removed and
  # strings kept, over the whole text, so a call split across lines is seen too. It refuses
  # the module erx_pipe_nif followed by one of the three names: as a remote call or a fun
  # (erx_pipe_nif:make_lock), as an apply passes them (erx_pipe_nif, make_lock), any
  # import from erx_pipe_nif, and a macro whose body is the module, the usual way to
  # call it through a name. Tests, under test/, are outside the scope and call them
  # freely. Like DevicePosters it catches a slip, not a module that holds the module name
  # in a variable; erx_pipe_srv itself calls through one, its nif option.
  module PipeMakers
    SITES = %w[erlang/apps/erx/src/erx_pipe_srv.erl erlang/apps/erx/src/erx_pipe_nif.erl].freeze
    MAKERS = %w[make_lock make_lane make_bell].freeze
    MADE = /
      #{DevicePosters::ATOM.call('erx_pipe_nif')} \s* (?: : | , ) \s* (?:#{MAKERS.map { |name| DevicePosters::ATOM.call(name) }.join('|')})
      | -\s*import\s*\(\s*#{DevicePosters::ATOM.call('erx_pipe_nif')}
      | -\s*define\s*\(\s*[^,()]+,\s*#{DevicePosters::ATOM.call('erx_pipe_nif')}\s*\)
    /x

    Violation = Data.define(:path, :line) do
      def to_s = "chokepoint pipe-makers: #{path}:#{line}: only #{SITES.first} may call " \
                 "erx_pipe_nif:#{MAKERS.join(', ')}"
    end

    module_function

    def covers?(path) = DeviceCallers.covers?(path)

    # The violations among files, a map of path to source text.
    def violations(files)
      files.flat_map do |path, text|
        next [] if !covers?(path) || SITES.include?(path)

        code = DeviceCallers.code(text)
        code.to_enum(:scan, MADE).map do
          Violation.new(path: path, line: code[0, Regexp.last_match.begin(0)].count("\n") + 1)
        end
      end
    end
  end
end
