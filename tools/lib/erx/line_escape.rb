# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require_relative 'generated_terminal_tables'

module Erx
  # The host tool's line escape, the twin of erx_text:escape_line/1
  # (docs/design-live.md, "Attributed text"): what the host tool's printer
  # shows of any text it prints from the guest. Every character of the unsafe
  # classes of abi/terminal.txt is written as its code point token, <U+202E>,
  # and every byte that does not begin or continue a valid, shortest UTF-8
  # sequence as its byte token, <0xC0>; every other character passes
  # unchanged, the backslash and < among them. The classes and the tokens'
  # texts come from the generated tables, which erx_text reads too, and
  # test/fixtures/line_escape_vectors.json holds what both must answer.
  module LineEscape
    RANGES = Generated::TerminalTables::UNICODE_UNSAFE_RANGES
    TOKENS = Generated::TerminalTables::CATALOG.fetch('token')
    # One unit of a byte string: a well-formed UTF-8 sequence, as the Unicode
    # Standard's table 3-7 lists them (so no overlong form, encoded surrogate
    # or code point past U+10FFFF), or else one byte.
    UNIT = Regexp.new('[\x00-\x7f]|[\xc2-\xdf][\x80-\xbf]|\xe0[\xa0-\xbf][\x80-\xbf]|' \
                      '[\xe1-\xec\xee\xef][\x80-\xbf]{2}|\xed[\x80-\x9f][\x80-\xbf]|' \
                      '\xf0[\x90-\xbf][\x80-\xbf]{2}|[\xf1-\xf3][\x80-\xbf]{3}|\xf4[\x80-\x8f][\x80-\xbf]{2}|.'.b,
                      Regexp::MULTILINE | Regexp::NOENCODING)

    module_function

    # The line escape of value's bytes, whatever its encoding says, as a
    # UTF-8 string.
    def escape(value)
      value.to_s.b.scan(UNIT).map { |unit| render(unit) }.join.force_encoding(Encoding::UTF_8)
    end

    # A unit of one byte at or above 0x80 begins no well-formed sequence.
    def render(unit)
      return token(unit.ord, 'byte') if unit.bytesize == 1 && unit.ord >= 0x80

      character = unit.dup.force_encoding(Encoding::UTF_8)
      unsafe?(character.ord) ? token(character.ord, 'codepoint') : unit
    end
    private_class_method :render

    def unsafe?(point)
      index = RANGES.bsearch_index { |_first, last| last >= point }
      !index.nil? && RANGES[index].first <= point
    end
    private_class_method :unsafe?

    def token(value, name)
      spec = TOKENS.fetch(name)
      digits = value.to_s(16).upcase.rjust(spec.fetch('minimum'), '0')
      "#{spec.fetch('prefix')}#{digits}#{spec.fetch('suffix')}"
    end
    private_class_method :token
  end
end
