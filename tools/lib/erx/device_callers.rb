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
  # string a caller could turn into one. erx_irq_line, which binds and acknowledges lines for
  # drivers (docs/design-shared-devices.md, "Lines inside a domain"), is the one other module
  # of erx that names it, and only it and erx_device name irq_bind_owner, a shared line's bind,
  # so no driver binds a shared line and takes its deliveries from the drivers joined to its
  # owner (SD3). Like the C text rules it catches a slip, not a
  # determined bypass that builds the atom from pieces; what keeps a device from other
  # domains is that its capability is installed only in its driver's domain.
  module DeviceCallers
    MODULE = 'erx_device'
    # Applications whose modules drive a device class.
    DRIVER_APPLICATIONS = %w[erx_blk erx_uart].freeze
    # erXos's own directory of an application that also runs outside erXos, whose other
    # modules name nothing of erXos's: the network stack's virtio transport
    # (docs/design-network-stack.md, "Two places, four seams").
    DRIVER_DIRECTORIES = %w[erlang/apps/erx_net/erxos].freeze
    SCOPE = %w[otp/**/*.{erl,hrl} erlang/**/*.{erl,hrl}].freeze
    LINE_MODULE = 'erlang/apps/erx/src/erx_irq_line.erl'
    SITES = ['erlang/apps/erx/src/erx_device.erl', LINE_MODULE,
             *DRIVER_APPLICATIONS.map { |application| "erlang/apps/#{application}/**/*" },
             *DRIVER_DIRECTORIES.map { |directory| "#{directory}/**/*" }].freeze
    GLOB_FLAGS = File::FNM_PATHNAME | File::FNM_EXTGLOB
    NAMED = /(?<![A-Za-z0-9_@])#{MODULE}(?![A-Za-z0-9_@])/
    LINE_CALLS = /(?<![A-Za-z0-9_@])irq_(?:bind|bind_owner|ack)(?![A-Za-z0-9_@])/
    LINE_CALL_SITES = ['erlang/apps/erx/src/erx_device.erl', LINE_MODULE].freeze
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
    Violation = Data.define(:path, :line, :rule) do
      def to_s = "chokepoint device-callers: #{path}:#{line}: #{rule}"
    end
    NAMING_RULE = "only erx_device, erx_irq_line and the driver applications " \
                  "(#{[*DRIVER_APPLICATIONS, *DRIVER_DIRECTORIES].join(', ')}) may name #{MODULE}".freeze
    LINE_CALL_RULE = 'only erx_device and erx_irq_line may name irq_bind, irq_bind_owner or irq_ack: ' \
                     'a driver attaches and acknowledges its lines through erx_irq_line'

    module_function

    # Whether a path is an Erlang source the rule reads.
    def covers?(path) = SCOPE.any? { |glob| File.fnmatch?(glob, path, GLOB_FLAGS) }

    # The violations among files, a map of path to source text.
    def violations(files)
      files.flat_map do |path, text|
        next [] unless covers?(path)

        lines = code(text).each_line.with_index(1).to_a
        [*matches(path, lines, NAMED, SITES, NAMING_RULE), *matches(path, lines, LINE_CALLS, LINE_CALL_SITES, LINE_CALL_RULE)]
      end
    end

    # The lines of `path` that name `pattern`, unless the path is one of `sites`.
    def matches(path, lines, pattern, sites, rule)
      return [] if sites.any? { |site| File.fnmatch?(site, path, GLOB_FLAGS) }

      lines.filter_map { |line, number| Violation.new(path: path, line: number, rule: rule) if pattern.match?(line) }
    end

    # The text with each comment blanked and every line kept, so line numbers still hold.
    def code(text)
      text.b.gsub(LEXEME) { Regexp.last_match[:comment] ? '' : Regexp.last_match[:kept] }
    end
  end
end
