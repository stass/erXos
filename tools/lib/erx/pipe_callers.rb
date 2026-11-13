# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require_relative 'device_callers'
require_relative 'device_posters'

module Erx
  # The Erlang halves of the pipe's "only X may call Y" chokepoints (docs/design-pipes.md,
  # invariant PI1 and Verification, build checks of the hand-offs). Each rule names the
  # Erlang sources that may mention what it guards; every other source in scope that
  # mentions it is refused.
  #
  # * pipe-makers: only erx_pipe_srv, the session's pipe server, calls erx_pipe_nif's
  #   make_lock/1, make_lane/1, make_bell/3 and hand_make/2, which make a pipe's lock, its
  #   lanes, its ends' bells and the hand-offs that give them to programs, each for a step
  #   its pure core (erx_pipe) decided.
  # * pipe-holders: only erx_prog_handler, a program's handler, calls
  #   erx_pipe_nif:program_holder/1 and holder_drop/1, which make and let go the holder
  #   entry by which the handler speaks for its program.
  # * pipe-holder-gone-erlang: only erx_pipe_srv names the atom erx_pipe_holder_gone, the
  #   program's gone the NIF sends it, so no Erlang process says a program is gone. Its C
  #   half, that only erx_pipe_nif.c sends it, is the Forbidden rule pipe-holder-gone
  #   (chokepoint_rules/pipe.rb).
  #
  # A call rule refuses the module erx_pipe_nif followed by one of its names: as a remote
  # call or a fun (erx_pipe_nif:make_lock), as an apply passes them (erx_pipe_nif,
  # make_lock), any import from erx_pipe_nif, and a macro whose body is the module, the
  # usual way to call it through a name. The atom rule refuses the atom, bare or quoted,
  # anywhere in code. Each reads the Erlang sources DeviceCallers reads, with comments
  # removed and strings kept, over the whole text, so a call split across lines is seen
  # too. Tests, under test/, are outside the scope. Like DevicePosters a rule catches a
  # slip, not a module that holds the module name in a variable (erx_pipe_srv itself calls
  # through one, its nif option) or an atom built at run time.
  module PipeCallers
    NIF_MODULE = 'erlang/apps/erx/src/erx_pipe_nif.erl'
    SERVER = 'erlang/apps/erx/src/erx_pipe_srv.erl'
    HANDLER = 'erlang/apps/erx/src/erx_prog_handler.erl'

    # name: the chokepoint; sites: the sources that may mention it; guarded: what they alone
    # may mention, for the message; pattern: the mention.
    Rule = Data.define(:name, :sites, :guarded, :pattern)

    NIF = DevicePosters::ATOM.call('erx_pipe_nif')
    CALLS = lambda do |names|
      /
        #{NIF} \s* (?: : | , ) \s* (?:#{names.map { |name| DevicePosters::ATOM.call(name) }.join('|')})
        | -\s*import\s*\(\s*#{NIF}
        | -\s*define\s*\(\s*[^,()]+,\s*#{NIF}\s*\)
      /x
    end

    MAKERS = %w[make_lock make_lane make_bell hand_make].freeze
    HOLDS = %w[program_holder holder_drop].freeze
    RULES = [
      Rule.new(name: 'pipe-makers', sites: [SERVER, NIF_MODULE].freeze,
               guarded: "calls of erx_pipe_nif:#{MAKERS.join(', ')}", pattern: CALLS.call(MAKERS)),
      Rule.new(name: 'pipe-holders', sites: [HANDLER, NIF_MODULE].freeze,
               guarded: "calls of erx_pipe_nif:#{HOLDS.join(', ')}", pattern: CALLS.call(HOLDS)),
      Rule.new(name: 'pipe-holder-gone-erlang', sites: [SERVER].freeze,
               guarded: 'the atom erx_pipe_holder_gone',
               pattern: Regexp.new(DevicePosters::ATOM.call('erx_pipe_holder_gone')))
    ].freeze

    Violation = Data.define(:rule, :path, :line) do
      def to_s = "chokepoint #{rule.name}: #{path}:#{line}: only #{rule.sites.join(' and ')} may hold #{rule.guarded}"
    end

    module_function

    def covers?(path) = DeviceCallers.covers?(path)

    # The violations among files, a map of path to source text.
    def violations(files)
      files.flat_map do |path, text|
        next [] unless covers?(path)

        code = DeviceCallers.code(text)
        RULES.reject { |rule| rule.sites.include?(path) }.flat_map do |rule|
          code.to_enum(:scan, rule.pattern).map do
            Violation.new(rule: rule, path: path, line: code[0, Regexp.last_match.begin(0)].count("\n") + 1)
          end
        end
      end
    end
  end
end
