# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require_relative 'device_callers'

module Erx
  # The chokepoint on the envelope of a message from another domain (docs/design.md,
  # "Chokepoint checks"; docs/design-domains.md, D18): edit 16 delivers every such
  # message as {erx_origin, D, Msg}, and in OTP's applications only the owners of the
  # protocols that cross domains take it apart, each for its own shapes. sys and
  # proc_lib above all must not, or a peer could steer any behaviour process.
  #
  # The check reads every Erlang source under otp/ with comments removed and strings
  # blanked, as DeviceCallers reads them, and refuses the atom erx_origin, bare or
  # quoted, in any module but the owners. It refuses a mention, not only a match, so
  # a module that builds the envelope fails too; like the other text rules it catches
  # a slip, not an atom made from pieces with list_to_atom/1 or a quoted atom spelled
  # with escapes, such as '\x65rx_origin', nor a match by shape alone, {_, _, M}. That
  # sys never acts on another domain's message is proved by the QEMU cases that send
  # one (design-domains, "Origins"); this check keeps the owners' list from slips.
  # erXos's own applications under erlang/ are outside it: each owns its protocol and
  # takes the envelope whole.
  #
  # OWNERS holds the modules whose unwrap is built, a subset of the owners design.md's
  # chokepoint row names: gen and io take replies (edits 58 and 60), and erts_internal's
  # dist_spawn_init a spawn's argument list. Each later edit adds its own module.
  module OriginUnwraps
    SCOPE = %w[otp/**/*.{erl,hrl}].freeze
    GLOB_FLAGS = File::FNM_PATHNAME | File::FNM_EXTGLOB
    OWNERS = %w[
      otp/lib/stdlib/src/gen.erl
      otp/lib/stdlib/src/io.erl
      otp/erts/preloaded/src/erts_internal.erl
    ].freeze
    ENVELOPE = /(?<![A-Za-z0-9_@'])(?:erx_origin|'erx_origin')(?![A-Za-z0-9_@'])/

    Violation = Data.define(:path, :line) do
      def to_s = "chokepoint origin-unwraps: #{path}:#{line}: only #{OWNERS.map { |owner| File.basename(owner, '.erl') }.join(', ')} " \
                 'may name erx_origin, the envelope of a message from another domain (D18)'
    end

    module_function

    def covers?(path) = SCOPE.any? { |glob| File.fnmatch?(glob, path, GLOB_FLAGS) }

    # The violations among files, a map of path to source text.
    def violations(files)
      files.select { |path, _| covers?(path) && !OWNERS.include?(path) }.flat_map do |path, text|
        code_text(text).each_line.with_index(1).flat_map do |line, number|
          line.scan(ENVELOPE).map { Violation.new(path: path, line: number) }
        end
      end
    end

    # The code with comments removed and every string and character blanked, lines
    # kept; a quoted atom stays, since 'erx_origin' is the same atom.
    def code_text(text)
      text.b.gsub(DeviceCallers::LEXEME) do
        found = Regexp.last_match
        if found[:comment] then ''
        elsif found[:kept].start_with?("'") then found[:kept]
        else found[:kept].gsub(/[^\n]/, ' ')
        end
      end
    end
  end
end
