# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'open3'
require 'optparse'
require 'tmpdir'
require_relative '../lib/erx/error'

# The fuzz targets of erx_text's line escape and field escape
# (test/erlang/erx_text_fuzz.erl), one per escape, compiled from source with
# the generated tables and run on stock's emulator (ERX_ERL and ERX_ERLC, the
# oracle's). Each runs the module as it is, then copies of erx_text with one
# fault the target must catch, which shows that it reaches each escape's
# classes, its handling of invalid UTF-8 and its inverse: for the line
# escape, one that lets DEL through, one that escapes only the C0 controls and
# one that writes an invalid byte raw; for the field escape, one that lets DEL
# through, one that writes an invalid byte raw, one that does not double a
# backslash, and one whose inverse accepts text the escape does not write.
module ErxTextFuzz
  ROOT = File.expand_path('../..', __dir__)
  TABLES = File.join(ROOT, 'erlang/apps/erx/src/erx_text_tables.erl')
  TEXT_SOURCE = File.join(ROOT, 'erlang/apps/erx/src/erx_text.erl')
  TARGET_SOURCE = File.join(ROOT, 'test/erlang/erx_text_fuzz.erl')
  DEADLINE_SECONDS = '150'
  COMPILE_SECONDS = '60'

  Fault = Data.define(:what, :anchor, :replacement, :markers)

  FAULTS = {
    'line' => [
      Fault.new(what: 'a line escape that lets DEL through',
                anchor: 'line_bytes(<<C, Rest/binary>>, Tokens, Acc) when C >= 16#20, C < 16#7F ->',
                replacement: 'line_bytes(<<C, Rest/binary>>, Tokens, Acc) when C >= 16#20, C =< 16#7F ->',
                markers: %w[unsafe_output line_differs_from_reference]),
      Fault.new(what: 'a line escape of the C0 controls only',
                anchor: "    case unsafe(Point) of\n        true -> token(Point, PointToken);",
                replacement: "    case unsafe(Point) andalso Point < 16#20 of\n        true -> token(Point, PointToken);",
                markers: %w[unsafe_output line_differs_from_reference]),
      Fault.new(what: 'a line escape that writes an invalid byte raw',
                anchor: 'line_bytes(Rest, Tokens, [token(B, ByteToken) | Acc]).',
                replacement: 'line_bytes(Rest, Tokens, [B | Acc]).', markers: %w[output_not_utf8])
    ],
    'field' => [
      Fault.new(what: 'a field escape that lets DEL through',
                anchor: 'field(<<C, Rest/binary>>, Token, Acc) when C >= 16#20, C < 16#7F ->',
                replacement: 'field(<<C, Rest/binary>>, Token, Acc) when C >= 16#20, C =< 16#7F ->',
                markers: %w[unsafe_output]),
      Fault.new(what: 'a field escape that writes an invalid byte raw',
                anchor: "field(<<B, Rest/binary>>, Token, Acc) ->\n    field(Rest, Token, [token(B, Token) | Acc]).",
                replacement: "field(<<B, Rest/binary>>, Token, Acc) ->\n    field(Rest, Token, [B | Acc]).",
                markers: %w[output_not_utf8]),
      Fault.new(what: 'a field escape that does not double a backslash',
                anchor: 'field(Rest, Token, [<<"\\\\\\\\">> | Acc]);',
                replacement: 'field(Rest, Token, [<<"\\\\">> | Acc]);', markers: %w[field_round_trip]),
      Fault.new(what: 'an inverse that accepts text the field escape does not write',
                anchor: 'case escape_field(Bytes) =:= Text of', replacement: 'case is_binary(Text) of',
                markers: %w[field_unescape_not_inverse])
    ]
  }.freeze

  module_function

  def run(target:, seed:)
    text = File.binread(TEXT_SOURCE)
    output, status = fuzz(text, target: target, seed: seed)
    abort(output) unless status.success? && output.match?(/^fuzz: \d+ inputs ok$/)
    FAULTS.fetch(target).each do |fault|
      raise Erx::Error, "no #{fault.anchor} in erx_text" unless text.include?(fault.anchor)

      # A block, so a backslash in the replacement is not a back-reference.
      output, status = fuzz(text.sub(fault.anchor) { fault.replacement }, target: target, seed: seed)
      if output.match?(/^fuzz: \d+ inputs ok$/) || fault.markers.none? { |marker| output.include?(marker) }
        abort("#{fault.what} passed:\n#{output}")
      end
    end
    puts "erx_text's #{target} escape keeps every property over its inputs, and none of " \
         "#{FAULTS.fetch(target).map(&:what).join(', ')} does"
  end

  # In a directory of its own, which also takes the crash dump of a failed run.
  def fuzz(text_source, target:, seed:)
    Dir.mktmpdir('erx-text-fuzz') do |work|
      text = File.join(work, 'erx_text.erl').tap { |path| File.binwrite(path, text_source) }
      output, status = Open3.capture2e('gtimeout', '-k', '10', COMPILE_SECONDS, ENV.fetch('ERX_ERLC'), '-o', work,
                                       TABLES, text, TARGET_SOURCE, stdin_data: '')
      raise Erx::Error, output unless status.success?

      Open3.capture2e('gtimeout', '-k', '10', DEADLINE_SECONDS, ENV.fetch('ERX_ERL'), '-noshell', '-pa', work,
                      '-run', 'erx_text_fuzz', 'run', target, seed.to_s, '-s', 'init', 'stop',
                      chdir: work, stdin_data: '')
    end
  end
end

if $PROGRAM_NAME == __FILE__
  options = { seed: 1, target: nil }
  OptionParser.new do |flags|
    flags.on('--seed N', Integer) { |value| options[:seed] = value }
    flags.on('--target NAME', ErxTextFuzz::FAULTS.keys) { |value| options[:target] = value }
  end.parse!
  raise OptionParser::MissingArgument, '--target line or field' unless options[:target]

  ErxTextFuzz.run(**options)
end
