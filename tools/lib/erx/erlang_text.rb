# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

module Erx
  # The Erlang view a text check reads: the sources that can enter a release, everything
  # under otp/ and erlang/, with comments blanked and every line kept, so a line number
  # of the view is the line number of the file. The chokepoints' Erlang rules
  # (Chokepoints::ErlangForbidden) and the other checks of Erlang sources read it.
  #
  # Like the C view it reads names, so a rule over it catches a slip, not a determined
  # bypass that builds an atom from pieces at run time (list_to_atom/1) or holds a module
  # in a variable; what such a rule guards is held by the capability or the process
  # behind it, and the modules it allows are kept few enough to review.
  module ErlangText
    SCOPE = %w[otp/**/*.{erl,hrl} erlang/**/*.{erl,hrl}].freeze
    GLOB_FLAGS = File::FNM_PATHNAME | File::FNM_EXTGLOB
    # Erlang's lexical forms that can hold a % or a quote (otp/lib/stdlib/src/erl_scan.erl):
    # a triple-quoted string, which ends at a line of only its run of quotes; a sigil,
    # ~Name and a string between one of its delimiter pairs, where the vanilla sigil, ~b
    # and ~s take escapes and any other name is verbatim; a string; a quoted atom; and a
    # character literal. A % outside them starts a comment that runs to the end of the line.
    TRIPLE = /(?<quotes>"{3,})[^\n]*\n.*?^[ \t]*\k<quotes>(?!")/m
    DELIMITERS = { '(' => ')', '[' => ']', '{' => '}', '<' => '>', '/' => '/', '|' => '|',
                   "'" => "'", '"' => '"', '`' => '`', '#' => '#' }.freeze
    ESCAPED = DELIMITERS.map { |left, right| "#{Regexp.escape(left)}(?:[^#{Regexp.escape(right)}\\\\]|\\\\.)*#{Regexp.escape(right)}" }
    VERBATIM = DELIMITERS.map { |left, right| "#{Regexp.escape(left)}[^#{Regexp.escape(right)}]*#{Regexp.escape(right)}" }
    LEXEME = /
      (?<kept>#{TRIPLE}
        | ~[bs]?(?:#{TRIPLE}|#{ESCAPED.join('|')})
        | ~[A-Za-z][A-Za-z0-9_@]*(?:#{TRIPLE}|#{VERBATIM.join('|')})
        | "(?:[^"\\]|\\.)*" | '(?:[^'\\]|\\.)*' | \$(?:\\.|.))
      | (?<comment>%[^\n]*)
    /mx

    # The atom name, bare or quoted, as a whole name: not part of a longer name.
    ATOM = ->(name) { "(?<![A-Za-z0-9_@'])(?:#{name}|'#{name}')(?![A-Za-z0-9_@'])" }
    NOT_NAME = "(?![A-Za-z0-9_@'])"
    # A variable or a macro other than ?MODULE: a module named by neither an atom nor itself.
    INDIRECT = "(?:(?<![A-Za-z0-9_@'?])[A-Z_][A-Za-z0-9_@]*|\\?(?!MODULE#{NOT_NAME})[A-Za-z_][A-Za-z0-9_@]*)"

    module_function

    def matches?(globs, path) = globs.any? { |glob| File.fnmatch?(glob, path, GLOB_FLAGS) }

    # Whether a path is an Erlang source the checks read.
    def covers?(path) = matches?(SCOPE, path)

    # The text with each comment blanked and every line kept. Strings stay, since a string
    # is an atom a caller could make with list_to_atom/1.
    def code(text)
      text.b.gsub(LEXEME) { Regexp.last_match[:comment] ? '' : Regexp.last_match[:kept] }
    end

    # The text with each comment and each string (doc strings included) blanked and every
    # line kept. Quoted atoms and character literals are kept.
    def code_without_strings(text)
      text.b.gsub(LEXEME) do
        kept = Regexp.last_match[:kept]
        if kept.nil? then ''
        elsif kept.start_with?('"', '~') then " #{"\n" * kept.count("\n")}"
        else kept
        end
      end
    end

    # The view a rule reads: strings :kept or :blanked.
    def view(text, strings:) = strings == :kept ? code(text) : code_without_strings(text)

    # The line at a byte offset of a view.
    def line_at(code, offset) = code[0, offset].count("\n") + 1
  end
end
