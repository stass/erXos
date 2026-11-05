# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

module Erx
  # The chokepoint "only the driver's modules reference the device NIF"
  # (docs/design-runtime.md, "The device NIF"). The NIF is erx_device's: ERTS binds a
  # static NIF only to the module of its name, and erx_device's register calls are BIFs
  # of that module, so Erlang reaches a device only by naming erx_device. The rule is
  # therefore that only erx_device itself and the modules of driver applications, one
  # per device class (docs/design.md, the tree layout), name it.
  #
  # The check reads the Erlang sources that can enter a release, everything under otp/
  # and erlang/, with comments removed and strings kept, and refuses the atom erx_device
  # anywhere else: a remote call, an apply with the module literal, a quoted atom or a
  # string a caller could turn into one. Like the C text rules it catches a slip, not a
  # determined bypass that builds the atom from pieces; what keeps a device from other
  # domains is that its capability is installed only in its driver's domain.
  module DeviceCallers
    MODULE = 'erx_device'
    # Applications whose modules drive a device class.
    DRIVER_APPLICATIONS = %w[erx_uart].freeze
    SCOPE = %w[otp/**/*.{erl,hrl} erlang/**/*.{erl,hrl}].freeze
    SITES = ['erlang/apps/erx/src/erx_device.erl',
             *DRIVER_APPLICATIONS.map { |application| "erlang/apps/#{application}/**/*" }].freeze
    GLOB_FLAGS = File::FNM_PATHNAME | File::FNM_EXTGLOB
    NAMED = /(?<![A-Za-z0-9_@])#{MODULE}(?![A-Za-z0-9_@])/
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
    Violation = Data.define(:path, :line) do
      def to_s = "chokepoint device-callers: #{path}:#{line}: only erx_device and the driver applications " \
                 "(#{DRIVER_APPLICATIONS.join(', ')}) may name #{MODULE}"
    end

    module_function

    # Whether a path is an Erlang source the rule reads.
    def covers?(path) = SCOPE.any? { |glob| File.fnmatch?(glob, path, GLOB_FLAGS) }

    # The violations among files, a map of path to source text.
    def violations(files)
      files.flat_map do |path, text|
        next [] if !covers?(path) || SITES.any? { |site| File.fnmatch?(site, path, GLOB_FLAGS) }

        code(text).each_line.with_index(1).filter_map { |line, number| Violation.new(path: path, line: number) if NAMED.match?(line) }
      end
    end

    # The text with each comment blanked and every line kept, so line numbers still hold.
    def code(text)
      text.b.gsub(LEXEME) { Regexp.last_match[:comment] ? '' : Regexp.last_match[:kept] }
    end
  end
end
