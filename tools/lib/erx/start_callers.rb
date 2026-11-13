# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require_relative 'device_callers'
require_relative 'device_posters'

module Erx
  # The chokepoints of the start table (docs/design-apps.md, invariants AP1 and AP2, and
  # "Verification and testing"): who starts a session, and who names its display.
  #
  # * starter-reach: erx_starter's modules reach the domain service only through
  #   erx_domain:start_session/2 and erx_domain:stop/2, and wait for the system domain's
  #   namespace with erx_domain:system_namespace/0, which changes nothing, before the
  #   first read of rc.conf, and for a display's server with erx_domain:display_settled/1,
  #   which changes nothing either, before a row that names it starts. They may also
  #   read a domain handle
  #   with erx_domain:id/1 and pid/1, which take the handle's fields apart and reach
  #   nothing. Any other mention of an erx_domain* atom (erx_domain:create/1, the
  #   erx_domain_srv server's name, an apply's module argument, an import, a macro) is
  #   refused, and so is a call through a module held in a variable or a macro other than
  #   ?MODULE, and a call of apply/2,3 or erlang:apply. Other calls that take a module
  #   and a function (spawn/3, timer:apply_after/4, erpc:call/4) are not refused; with
  #   every erx_domain* atom refused, the module they name would have to come from
  #   outside the module's source.
  # * start-callers: only erx_console and erx_starter_keeper call
  #   erx_domain:start_session/2 (AP2's source half; the web login joins the list when it
  #   is built). Refused elsewhere: the remote call or fun, an apply naming erx_domain and
  #   start_session, a start_session call through a variable or macro module or an
  #   apply's variable, any import from erx_domain, a macro whose body is erx_domain, and,
  #   outside erx_domain's own application, the service's registered name erx_domain_srv,
  #   which start_session/2 calls.
  # * start-display: only erx_starter passes display or default_display to
  #   start_session/2. Every module outside erx_starter that has a start-callers form names
  #   neither atom, except as a function name. A start map built in another module that
  #   never starts a session escapes this rule (TODO.md, the start table's display key).
  #
  # The rules read the Erlang sources DeviceCallers reads, with comments and strings
  # (doc strings included) blanked and line breaks kept, over the whole text, so a call
  # split across lines is seen too. Tests, under test/, are outside the scope. Like
  # PipeCallers they catch a slip, not an atom built at run time (list_to_atom/1).
  module StartCallers
    STARTER = 'erlang/apps/erx_starter/**/*'
    CALLERS = %w[erlang/apps/erx/src/erx_console.erl erlang/apps/erx_starter/src/erx_starter_keeper.erl].freeze
    # start_session/2 and stop/2; system_namespace/0, the wait before the first read of
    # rc.conf, which changes nothing; display_settled/1, the wait before a row that names
    # a display starts, which changes nothing either; the handle's accessors id/1 and pid/1, which reach
    # nothing; and the handle's types, domain() and spec(), which a -spec names.
    STARTER_REACHES = %w[start_session stop system_namespace display_settled id pid domain spec].freeze
    # The domain service's registered name, which only erx_domain's own modules name.
    SERVICE = 'erx_domain_srv'
    DOMAIN_APP = 'erlang/apps/erx_domain/**/*'
    DISPLAY_KEYS = %w[display default_display].freeze

    ATOM = DevicePosters::ATOM
    NOT_NAME = "(?![A-Za-z0-9_@'])"
    # A variable or a macro other than ?MODULE: a module named by neither an atom nor itself.
    INDIRECT = "(?:(?<![A-Za-z0-9_@'?])[A-Z_][A-Za-z0-9_@]*|\\?(?!MODULE#{NOT_NAME})[A-Za-z_][A-Za-z0-9_@]*)"
    # An atom or a variable in a function's place.
    FUNCTION = "(?:[A-Za-z_][A-Za-z0-9_@]*|'(?:[^'\\\\]|\\\\.)*')"

    # Scanned left to right: at each place the allowed call is tried first, so an
    # erx_domain atom matches as a violation only where it is not that call.
    STARTER_FORMS = /
        (?<reach>#{ATOM.call('erx_domain')}\s*:\s*(?:#{STARTER_REACHES.map { |name| ATOM.call(name) }.join('|')}))
      | (?<domain>(?<![A-Za-z0-9_@'])'?erx_domain[A-Za-z0-9_@]*'?#{NOT_NAME})
      | (?<indirect>(?:#{INDIRECT})\s*:\s*#{FUNCTION}\s*\(|\bfun\s+(?:#{INDIRECT})\s*:)
      | (?<apply>#{ATOM.call('apply')}\s*[(\/])
    /x
    START = ATOM.call('start_session')
    STARTS = /
        #{ATOM.call('erx_domain')}\s*[:,]\s*#{START}
      | (?:#{INDIRECT})\s*:\s*#{START}
      | #{ATOM.call('apply')}\s*\(\s*[^,()]+,\s*#{START}
      | -\s*import\s*\(\s*#{ATOM.call('erx_domain')}
      | -\s*define\s*\(\s*[^,()]+(?:\([^()]*\))?\s*,\s*#{ATOM.call('erx_domain')}\s*\)
      | #{ATOM.call(SERVICE)}
    /x
    # The atom as data: not a remote call's function (after a colon), not a local call or
    # a fun's name (before a parenthesis or a slash).
    DISPLAY = /(?<!:)(?:#{DISPLAY_KEYS.map { |name| ATOM.call(name) }.join('|')})(?!\s*[(\/])/

    DETAILS = {
      'starter-reach' => {
        domain: 'erx_starter reaches the domain service only through erx_domain:start_session/2, ' \
                'erx_domain:stop/2, erx_domain:system_namespace/0 and erx_domain:display_settled/1 ' \
                '(and reads a handle with id/1 and pid/1); ' \
                'it names no other erx_domain ' \
                'function and no other erx_domain* module or name',
        indirect: "erx_starter's modules call no function through a module held in a variable or a macro",
        apply: "erx_starter's modules call no apply"
      },
      'start-callers' => { call: "only #{CALLERS.join(' and ')} call erx_domain:start_session/2" },
      'start-display' => { atom: 'only erx_starter passes display or default_display to erx_domain:start_session/2; ' \
                                 'a module outside it that starts a session names neither atom' }
    }.freeze

    Violation = Data.define(:rule, :path, :line, :kind) do
      def to_s = "chokepoint #{rule}: #{path}:#{line}: #{DETAILS.fetch(rule).fetch(kind)}"
    end

    module_function

    def covers?(path) = DeviceCallers.covers?(path)

    # The violations among files, a map of path to source text.
    def violations(files)
      files.flat_map do |path, text|
        next [] unless covers?(path)

        code = code_without_strings(text)
        starts = in_domain_app?(path) ? [] : matches(code, STARTS)
        reach_violations(path, code) + caller_violations(path, code, starts) + display_violations(path, code, starts)
      end
    end

    # The text with each comment and each string blanked and every line kept, so line
    # numbers still hold. Quoted atoms and character literals are kept. Unlike
    # DeviceCallers.code, strings go too: erx_starter's doc strings name erx_domain.
    def code_without_strings(text)
      text.b.gsub(DeviceCallers::LEXEME) do
        kept = Regexp.last_match[:kept]
        if kept.nil? then ''
        elsif kept.start_with?('"', '~') then " #{"\n" * kept.count("\n")}"
        else kept
        end
      end
    end

    def starter?(path) = File.fnmatch?(STARTER, path, DeviceCallers::GLOB_FLAGS)

    def in_domain_app?(path) = File.fnmatch?(DOMAIN_APP, path, DeviceCallers::GLOB_FLAGS)

    # starter-reach, over erx_starter's modules.
    def reach_violations(path, code)
      return [] unless starter?(path)

      code.to_enum(:scan, STARTER_FORMS).filter_map do
        match = Regexp.last_match
        kind = %i[domain indirect apply].find { |name| match[name] }
        Violation.new('starter-reach', path, line(code, match.begin(0)), kind) if kind
      end
    end

    # start-callers, over every module but the callers'.
    def caller_violations(path, code, starts)
      return [] if CALLERS.include?(path)

      starts.map { |at| Violation.new('start-callers', path, line(code, at), :call) }
    end

    # start-display, over every module outside erx_starter that starts a session.
    def display_violations(path, code, starts)
      return [] if starter?(path) || starts.empty?

      matches(code, DISPLAY).map { |at| Violation.new('start-display', path, line(code, at), :atom) }
    end

    def matches(code, pattern) = code.to_enum(:scan, pattern).map { Regexp.last_match.begin(0) }

    def line(code, offset) = code[0, offset].count("\n") + 1
  end
end
