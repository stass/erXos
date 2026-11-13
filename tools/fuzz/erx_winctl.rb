# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'open3'
require 'optparse'
require 'tmpdir'

# The fuzz target of erx_winctl:parse/1, the parser of a present written to a window's ctl
# file, whose bytes come from a client (docs/design-display.md, "The window tree" and
# "Verification and testing"). It is compiled from source and run alone on stock's
# emulator (ERX_ERL and ERX_ERLC, the oracle's), as the module is and then as copies that
# each drop one check, which must fail: without the 1,024-byte bound on a line, without
# the top of the 16,384-pixel size for the width and for the height, without the offset's
# bound below 2^63, without the 16-rectangle bound, without the top of the coordinate
# range, without the check that a rectangle is well formed, without the clip to the
# buffer, and without the 19-digit bound.
# That shows the reference and the inputs reach each check.
module ErxWinctlFuzz
  ROOT = File.expand_path('../..', __dir__)
  ABI_INCLUDE = File.join(ROOT, 'build/gen/erlang/apps/erx/include')
  MODULE_SOURCE = File.join(ROOT, 'erlang/apps/erx_display/src/erx_winctl.erl')
  TARGET_SOURCE = File.join(ROOT, 'test/erlang/erx_winctl_fuzz.erl')
  SEEDED = {
    'the 1,024-byte bound' => ['byte_size(Bytes) =< ?ERX_WINDOWS_LINE_MAX', 'byte_size(Bytes) >= 0'],
    'the 16,384-pixel size' => ['natural(Width, ?ERX_WINDOWS_SIDE_MAX)', 'natural(Width, ?MAX_OFFSET)'],
    'the 16,384-pixel height' => ['natural(Height, ?ERX_WINDOWS_SIDE_MAX)', 'natural(Height, ?MAX_OFFSET)'],
    'the offset bound' => ['natural(Offset, ?MAX_OFFSET)', 'natural(Offset, 2 * ?MAX_OFFSET)'],
    'the well-formed rectangle' => ['when X0 =< X1, Y0 =< Y1', 'when is_integer(X0)'],
    'the 16-rectangle bound' => ['length(Acc) >= ?ERX_WINDOWS_PRESENT_RECTS', 'length(Acc) >= 64'],
    'the coordinate range' => ['Sign * Magnitude =< ?ERX_WINDOWS_COORD_MAX', 'is_integer(Magnitude)'],
    'the clip' => ['[intersect(R, Buffer) || R <- Rects]', 'Rects'],
    'the 19-digit bound' => ['byte_size(Digits) > ?MAX_DIGITS', 'byte_size(Digits) < 0']
  }.freeze
  DEADLINE_SECONDS = '300'

  module_function

  def run(seed:)
    source = File.binread(MODULE_SOURCE)
    output, status = fuzz(source, seed: seed)
    abort(output) unless status.success? && output.match?(/^fuzz: \d+ rounds ok$/)
    SEEDED.each do |check, (text, wrong)|
      raise "no #{check} (#{text}) in #{MODULE_SOURCE}" unless source.include?(text)

      output, status = fuzz(source.sub(text, wrong), seed: seed)
      abort("a parser without #{check} passed:\n#{output}") if status.success? || !output.include?('disagrees_with_reference')
    end
    puts "erx_winctl:parse/1 agrees with its reference, and parsers without #{SEEDED.keys.join(' or ')} do not"
  end

  # In a directory of its own, which also takes the crash dump of a failed round.
  def fuzz(module_text, seed:)
    Dir.mktmpdir('erx-winctl-fuzz') do |work|
      module_path = File.join(work, 'erx_winctl.erl')
      File.binwrite(module_path, module_text)
      output, status = Open3.capture2e('gtimeout', '-k', '10', DEADLINE_SECONDS, ENV.fetch('ERX_ERLC'), '-I', ABI_INCLUDE, '-o', work, module_path, TARGET_SOURCE, stdin_data: '')
      raise output unless status.success?

      Open3.capture2e('gtimeout', '-k', '10', DEADLINE_SECONDS, ENV.fetch('ERX_ERL'), '-noshell', '-pa', work,
                      '-run', 'erx_winctl_fuzz', 'run', seed.to_s, '-s', 'init', 'stop', chdir: work, stdin_data: '')
    end
  end
end

if $PROGRAM_NAME == __FILE__
  seed = 1
  OptionParser.new { |flags| flags.on('--seed N', Integer) { |value| seed = value } }.parse!
  ErxWinctlFuzz.run(seed: seed)
end
