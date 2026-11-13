# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'open3'
require 'optparse'
require 'tmpdir'

# The fuzz target of erx_win_core's readers of what a client reads back from a display:
# the ctl read's channel, the wctl read's rectangle and state, and the mouse and kbd records
# (docs/design-display.md, "Verification and testing", Windows). It is compiled from source
# with erx_chan and run alone on stock's emulator (ERX_ERL and ERX_ERLC, the oracle's), as
# the module is and then as copies that each drop one check, which must fail: without the
# mouse record's length, without the wctl read's length, without the right alignment of a
# field, without the rectangle's form, without its 16,384-pixel side, without the sign
# check of the buttons, and without the refusal of a NUL among a kbd record's runes. That
# shows the reference and the inputs reach each check.
module ErxWinCoreFuzz
  ROOT = File.expand_path('../..', __dir__)
  MODULE_SOURCE = File.join(ROOT, 'erlang/apps/erx_win/src/erx_win_core.erl')
  CHAN_SOURCE = File.join(ROOT, 'erlang/apps/erx_memdraw/src/erx_chan.erl')
  TARGET_SOURCE = File.join(ROOT, 'test/erlang/erx_win_core_fuzz.erl')
  ABI_INCLUDE = File.join(ROOT, 'build/gen/erlang/apps/erx/include')
  SEEDED = {
    "the mouse record's length" => ['Msec:?CELL/binary>>)', 'Msec:?CELL/binary, _/binary>>)'],
    "the wctl read's length" => ['F:?CELL/binary>>)', 'F:?CELL/binary, _/binary>>)'],
    "a field's alignment" => ['byte_size(Token), byte_size(Token)) =:= Token', 'byte_size(Token), 0) =:= <<>>'],
    "the rectangle's form" => ['X0 =< X1, Y0 =< Y1, X1 - X0', 'X1 - X0'],
    'the 16,384-pixel side' => ['X1 - X0 =< ?ERX_WINDOWS_SIDE_MAX', 'X1 - X0 =< 2 * ?ERX_WINDOWS_SIDE_MAX'],
    "the buttons' sign" => ['number(Buttons, 0)', 'number(Buttons, ?ERX_WINDOWS_COORD_MIN)'],
    'the NUL among runes' => ['case lists:member(0, Runes) of', 'case false of']
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
      abort("readers without #{check} passed:\n#{output}") if status.success? || !output.include?('disagrees_with_reference')
    end
    puts "erx_win_core's readers agree with their reference, and readers without #{SEEDED.keys.join(' or ')} do not"
  end

  # In a directory of its own, which also takes the crash dump of a failed round.
  def fuzz(module_text, seed:)
    Dir.mktmpdir('erx-win-core-fuzz') do |work|
      module_path = File.join(work, 'erx_win_core.erl')
      File.binwrite(module_path, module_text)
      output, status = Open3.capture2e('gtimeout', '-k', '10', DEADLINE_SECONDS, ENV.fetch('ERX_ERLC'), '-I', ABI_INCLUDE, '-o', work,
                                       module_path, CHAN_SOURCE, TARGET_SOURCE, stdin_data: '')
      raise output unless status.success?

      Open3.capture2e('gtimeout', '-k', '10', DEADLINE_SECONDS, ENV.fetch('ERX_ERL'), '-noshell', '-pa', work,
                      '-run', 'erx_win_core_fuzz', 'run', seed.to_s, '-s', 'init', 'stop', chdir: work, stdin_data: '')
    end
  end
end

if $PROGRAM_NAME == __FILE__
  seed = 1
  OptionParser.new { |flags| flags.on('--seed N', Integer) { |value| seed = value } }.parse!
  ErxWinCoreFuzz.run(seed: seed)
end
