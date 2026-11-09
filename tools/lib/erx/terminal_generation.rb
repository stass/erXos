# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require_relative 'terminal_rules'
require_relative 'generation_plan'

module Erx
  module TerminalRules
    module_function

    def plan(root:) = generation(root: root).files

    # The plan Erx::Generated publishes into the build tree. abi/terminal.txt
    # names every other input, so the files read are the complete input
    # record of every output. Of otp/ORIGIN.md generation uses only each
    # input's import row, and refuses unless the row's sha256 equals the hash
    # of the bytes read and its licence is the one the outputs declare, so the
    # input hashes pin everything it takes from there and ORIGIN.md itself is
    # not recorded: an unrelated OTP import does not regenerate the tree.
    def generation(root:)
      root = File.realpath(root)
      source_bytes = read_input(File.join(root, 'abi/terminal.txt'), maximum: 65_536)
      model = source(source_bytes)
      origin = Origin.new(root: File.join(root, 'otp'))
      inputs = model.fetch('input').to_h do |name, path|
        bytes = read_input(File.join(root, path), maximum: 8 * 1024 * 1024)
        record = origin.imported_file(path.delete_prefix('otp/'))
        unless record && Digest::SHA256.hexdigest(bytes) == record.fetch('sha256') &&
               record.fetch('license') == LICENSE
          raise Error, 'terminal input differs from its pinned OTP origin'
        end
        [name, bytes]
      end
      records = unicode_data(inputs.fetch('unicode_data'))
      intervals = unsafe_intervals(model, records: records,
                                   ignorables: derived_properties(inputs.fetch('properties'), version: model.fetch('unicode')))
      widths = width_intervals(model, records: records,
                               widths: east_asian_widths(inputs.fetch('east_asian_width'), version: model.fetch('unicode')))
      catalog = { 'token' => model.fetch('token'), 'unicode' => model.fetch('unicode') }
      files = { OUTPUTS[0] => ascii_header(model), OUTPUTS[1] => erlang_tables(intervals, catalog),
                OUTPUTS[2] => ruby_tables(intervals, catalog), OUTPUTS[4] => typescript_tables(intervals, catalog),
                OUTPUTS[5] => erlang_widths(widths, unicode: model.fetch('unicode')),
                OUTPUTS[6] => c_widths(widths, unicode: model.fetch('unicode')) }
      notice = inputs.fetch('properties').lines.take_while { |line| line.start_with?('#') || line.strip.empty? }.join
                     .force_encoding(Encoding::UTF_8)
      input_hashes = model.fetch('input').to_h { |name, path| [path, Digest::SHA256.hexdigest(inputs.fetch(name))] }
      provenance = { 'version' => 1, 'unicode' => model.fetch('unicode'), 'license' => LICENSE,
                     'origin' => 'otp/ORIGIN.md', 'inputs' => input_hashes,
                     'original_unicode_notice' => notice }
      files[OUTPUTS[3]] = JSON.pretty_generate(provenance, ascii_only: true) + "\n"
      raise Error, 'generated terminal output is not ASCII' unless files.values.all?(&:ascii_only?)
      GenerationPlan.new(files: files.transform_values(&:freeze),
                         reads: input_hashes.merge('abi/terminal.txt' => Digest::SHA256.hexdigest(source_bytes)))
    rescue SystemCallError => error
      raise Error, "cannot read terminal generation input: #{error.message}"
    end

    def ascii_header(model)
      first, last = model.fetch('kernel_ascii').fetch('range')
      values = (0..255).map { |byte| byte.between?(first, last) ? 1 : 0 }
      rows = values.each_slice(16).map { |slice| "\t" + slice.join(', ') + ',' }
      token = model.fetch('token').fetch('kernel')
      unless token.fetch('minimum') == token.fetch('maximum') && token.fetch('suffix').empty?
        raise Error, 'the kernel escape token must be a prefix and a fixed count of hex digits'
      end
      prefix = token.fetch('prefix').gsub(/[\\"]/) { |character| "\\#{character}" }
      "/*\n * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>\n" \
        " * SPDX-License-Identifier: BSD-2-Clause\n * Generated from abi/terminal.txt; do not edit.\n */\n\n" \
        "#ifndef ERX_TERMINAL_ASCII_H\n#define ERX_TERMINAL_ASCII_H\n\n#include <stdint.h>\n\n" \
        "/* A byte index is always in bounds; values grant kernel text passthrough. */\n" \
        "static const uint8_t erx_terminal_ascii_safe[256] = {\n#{rows.join("\n")}\n};\n\n" \
        "/* A byte outside the class is written as this prefix and uppercase hex digits. */\n" \
        "#define ERX_TERMINAL_KERNEL_TOKEN_PREFIX \"#{prefix}\"\n" \
        "#define ERX_TERMINAL_KERNEL_TOKEN_DIGITS #{token.fetch('minimum')}\n\n#endif\n"
    end
    private_class_method :ascii_header

    def ruby_tables(intervals, catalog)
      "# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>\n" \
        "# SPDX-License-Identifier: BSD-2-Clause AND Unicode-3.0\n" \
        "# Generated from abi/terminal.txt and pinned OTP Unicode data; do not edit.\n" \
        "# Unicode notice and exact input identities: terminal_notices.json.\n# frozen_string_literal: true\n\n" \
        "module Erx\n  module Generated\n    module TerminalTables\n" \
        "      UNICODE_UNSAFE_RANGES = #{ruby_value(intervals)}\n" \
        "      CATALOG = #{ruby_value(catalog)}\n    end\n  end\nend\n"
    end
    private_class_method :ruby_tables

    def ruby_value(value)
      case value
      when Hash then '{' + value.sort.map { |key, member| "#{JSON.generate(key)} => #{ruby_value(member)}" }.join(",\n        ") + '}.freeze'
      when Array
        separator = value.any? { |member| member.is_a?(Array) || member.is_a?(Hash) } ? ",\n        " : ', '
        '[' + value.map { |member| ruby_value(member) }.join(separator) + '].freeze'
      when String then JSON.generate(value, ascii_only: true) + '.freeze'
      else value.inspect
      end
    end
    private_class_method :ruby_value

    # The web client's copy of the line escape's classes and tokens
    # (docs/design-web.md, "The client"), which web/src/text.ts reads. The
    # ranges are flat, each range's first and last code point in turn, so a
    # binary search reads them with no index built at load; JSON's string
    # literals are TypeScript's, and ascii_only keeps them ASCII.
    def typescript_tables(intervals, catalog)
      token = lambda do |name|
        spec = catalog.fetch('token').fetch(name)
        "Object.freeze({ prefix: #{JSON.generate(spec.fetch('prefix'), ascii_only: true)}, " \
          "minimum: #{Integer(spec.fetch('minimum'))}, suffix: #{JSON.generate(spec.fetch('suffix'), ascii_only: true)} })"
      end
      rows = intervals.flatten.map { |point| "0x#{point.to_s(16)}" }.each_slice(8).map { |row| "  #{row.join(', ')}," }
      "/*\n * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>\n" \
        " * SPDX-License-Identifier: BSD-2-Clause AND Unicode-3.0\n" \
        " * Generated by tools/gen_terminal.rb from abi/terminal.txt and pinned OTP Unicode data.\n" \
        " * Do not edit this file. Unicode notice: tools/generated/terminal_notices.json.\n *\n" \
        " * The line escape's unsafe characters, Unicode #{catalog.fetch('unicode')}, as sorted, disjoint\n" \
        " * ranges [first, last, first, last, ...], and its two tokens.\n */\n\n" \
        "export type Token = { readonly prefix: string; readonly minimum: number; readonly suffix: string };\n\n" \
        "export const UNICODE_UNSAFE_RANGES: readonly number[] = Object.freeze([\n#{rows.join("\n")}\n]);\n\n" \
        "/* A character of the unsafe classes. */\n" \
        "export const CODEPOINT_TOKEN: Token = #{token.call('codepoint')};\n\n" \
        "/* A byte that begins or continues no well-formed UTF-8 sequence. */\n" \
        "export const BYTE_TOKEN: Token = #{token.call('byte')};\n"
    end
    private_class_method :typescript_tables

    def erlang_tables(intervals, catalog)
      "%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>\n" \
        "%% SPDX-License-Identifier: BSD-2-Clause AND Unicode-3.0\n" \
        "%% Generated from abi/terminal.txt and pinned OTP Unicode data; do not edit.\n" \
        "%% Unicode notice: tools/generated/terminal_notices.json.\n" \
        "-module(erx_text_tables).\n-export([unicode_unsafe_ranges/0, catalog/0]).\n\n" \
        "%% A tuple supports bounded binary search without constructing an index.\n" \
        "unicode_unsafe_ranges() ->\n    {" + intervals.map { |first, last| "{16##{first.to_s(16)}, 16##{last.to_s(16)}}" }.join(",\n     ") + "}.\n\n" \
        "%% Names remain binaries; no source-derived atom is created.\n" \
        "catalog() ->\n    #{erlang_value(catalog)}.\n"
    end
    private_class_method :erlang_tables

    # erx_vt's width table: one sorted tuple of the ranges whose width is not 1,
    # which width/1 searches by halves, so a lookup costs about ten comparisons.
    def erlang_widths(ranges, unicode:)
      rows = ranges.map { |first, last, width| "{16##{first.to_s(16)}, 16##{last.to_s(16)}, #{width}}" }
      "%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>\n" \
        "%% SPDX-License-Identifier: BSD-2-Clause AND Unicode-3.0\n" \
        "%% Generated by tools/gen_terminal.rb from abi/terminal.txt and pinned OTP Unicode data; do not edit.\n" \
        "%% Unicode notice: tools/generated/terminal_notices.json.\n" \
        "%%\n%% The terminal's width of a code point, Unicode #{unicode} (docs/design-display.md,\n" \
        "%% \"Cells and the grid state\"): 0, 1 or 2 columns.\n" \
        "-module(erx_vt_width).\n-export([width/1]).\n\n" \
        "-spec width(0..16#10FFFF) -> 0 | 1 | 2.\n" \
        "width(Point) when is_integer(Point), Point >= 0, Point =< 16#10FFFF ->\n" \
        "    search(Point, ranges(), 1, tuple_size(ranges())).\n\n" \
        "%% The ranges First..Last, sorted and disjoint, holding Point if any does.\n" \
        "search(_Point, _Ranges, Low, High) when Low > High ->\n    1;\n" \
        "search(Point, Ranges, Low, High) ->\n" \
        "    Middle = (Low + High) div 2,\n" \
        "    case element(Middle, Ranges) of\n" \
        "        {First, _Last, _Width} when Point < First -> search(Point, Ranges, Low, Middle - 1);\n" \
        "        {_First, Last, _Width} when Point > Last -> search(Point, Ranges, Middle + 1, High);\n" \
        "        {_First, _Last, Width} -> Width\n" \
        "    end.\n\n" \
        "%% A literal, so the tuple is built once, when the module loads.\n" \
        "ranges() ->\n    {" + rows.join(",\n     ") + "}.\n"
    end
    private_class_method :erlang_widths

# The same table for C: erx_vt_width(), which libvterm, the oracle of
# erx_vt, is built with, so the two terminals agree on every width.
def c_widths(ranges, unicode:)
  rows = ranges.map { |first, last, width| format("\t{ 0x%06x, 0x%06x, %d },", first, last, width) }
  "/*\n * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>\n" \
    " * SPDX-License-Identifier: BSD-2-Clause AND Unicode-3.0\n" \
    " * Generated by tools/gen_terminal.rb from abi/terminal.txt and pinned OTP Unicode data; do not edit.\n" \
    " * Unicode notice: tools/generated/terminal_notices.json.\n *\n" \
    " * The terminal's width of a code point, Unicode #{unicode} (docs/design-display.md,\n" \
    " * \"Cells and the grid state\"): 0, 1 or 2 columns, the table of erx_vt_width.erl.\n */\n\n" \
    "#ifndef ERX_VT_WIDTH_H\n#define ERX_VT_WIDTH_H\n\n#include <stddef.h>\n#include <stdint.h>\n\n" \
    "/* The ranges whose width is not 1, sorted and disjoint. */\n" \
    "static const struct erx_vt_width_range {\n\tuint32_t first;\n\tuint32_t last;\n\tint width;\n" \
    "} erx_vt_width_ranges[] = {\n" + rows.join("\n") + "\n};\n\n" \
    "static inline int\nerx_vt_width(uint32_t point)\n{\n" \
    "\tsize_t low = 0, high = sizeof(erx_vt_width_ranges) / sizeof(erx_vt_width_ranges[0]);\n\n" \
    "\twhile (low < high) {\n\t\tsize_t middle = low + (high - low) / 2;\n\n" \
    "\t\tif (point < erx_vt_width_ranges[middle].first)\n\t\t\thigh = middle;\n" \
    "\t\telse if (point > erx_vt_width_ranges[middle].last)\n\t\t\tlow = middle + 1;\n" \
    "\t\telse\n\t\t\treturn (erx_vt_width_ranges[middle].width);\n\t}\n\treturn (1);\n}\n\n" \
    "#endif /* ERX_VT_WIDTH_H */\n"
end
private_class_method :c_widths

    def erlang_value(value)
      case value
      when Hash then '#{' + value.sort.map { |key, member| "#{erlang_value(key)} => #{erlang_value(member)}" }.join(",\n      ") + '}'
      when String then '<<' + JSON.generate(value, ascii_only: true) + '>>'
      else value.inspect
      end
    end
    private_class_method :erlang_value

    def read_input(path, maximum:)
      File.open(path, File::RDONLY | File::NONBLOCK) do |file|
        raise Error, 'terminal input is not a bounded regular file' unless file.stat.file? && file.size <= maximum
        bytes = file.read(maximum + 1) || ''.b
        raise Error, 'terminal input exceeds byte bound' if bytes.bytesize > maximum
        bytes
      end
    end
    private_class_method :read_input
  end
end
