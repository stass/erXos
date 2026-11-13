# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'open3'
require 'optparse'
require 'tmpdir'

# The fuzz target of erx_pl011:console_uart/1, the parse of the console's device words that
# the boot information carries to init's arguments, compiled from source and run alone on
# stock's emulator (ERX_ERL and ERX_ERLC, the oracle's), so it needs no hosted build. It runs
# the module as it is, then each seeded copy of MUTANTS, which must fail: a copy that takes
# the first of several entries shows the reference reads duplicates, one that accepts a
# clock of 0 Hz shows it refuses an entry whose clock would divide nothing, and one that
# takes a shared line for a direct one shows it holds the entry to its line's mark.
module ErxPl011ConsoleUartFuzz
  ROOT = File.expand_path('../..', __dir__)
  MODULE_SOURCE = File.join(ROOT, 'erlang/apps/erx_uart/src/erx_pl011.erl')
  TARGET_SOURCE = File.join(ROOT, 'test/erlang/erx_pl011_console_uart_fuzz.erl')
  # What each seeded copy says, the text it replaces and the text it plants.
  MUTANTS = {
    'taking the first of several entries' => ['[[Base, Size, Line, Mark, Clock | _]] ->', '[[Base, Size, Line, Mark, Clock | _] | _] ->'],
    'accepting a clock of 0 Hz' => ["{{ok, _}, {ok, _}, {ok, _}, {ok, 0}, _} ->\n" \
                                    "                    {error, {bad_console_uart, \"console_uart's clock is 0 Hz\"}};\n", ''],
    'reading a shared line as direct' => ['marked(shared, Line) -> {shared, Line}.', 'marked(shared, Line) -> Line.']
  }.freeze
  DEADLINE_SECONDS = '120'

  module_function

  def run(seed:)
    source = File.binread(MODULE_SOURCE)
    MUTANTS.each_value { |from, _to| raise "#{from.inspect} is not in #{MODULE_SOURCE}" unless source.include?(from) }

    output, status = fuzz(source, seed: seed)
    abort(output) unless status.success? && output.match?(/^fuzz: \d+ rounds ok, \d+ accepted$/)
    MUTANTS.each do |name, (from, to)|
      output, status = fuzz(source.sub(from, to), seed: seed)
      abort("#{name} passed:\n#{output}") if status.success? || !output.include?('disagrees_with_reference')
    end
    puts "erx_pl011:console_uart/1 agrees with its reference, and no seeded copy does (#{MUTANTS.keys.join('; ')})"
  end

  # In a directory of its own, which also takes the crash dump of a failed round.
  def fuzz(module_text, seed:)
    Dir.mktmpdir('erx-pl011-fuzz') do |work|
      module_path = File.join(work, 'erx_pl011.erl')
      File.binwrite(module_path, module_text)
      output, status = Open3.capture2e(ENV.fetch('ERX_ERLC'), '-o', work, module_path, TARGET_SOURCE, stdin_data: '')
      raise output unless status.success?

      Open3.capture2e('gtimeout', '-k', '10', DEADLINE_SECONDS, ENV.fetch('ERX_ERL'), '-noshell', '-pa', work,
                      '-run', 'erx_pl011_console_uart_fuzz', 'run', seed.to_s, '-s', 'init', 'stop',
                      chdir: work, stdin_data: '')
    end
  end
end

if $PROGRAM_NAME == __FILE__
  seed = 1
  OptionParser.new { |flags| flags.on('--seed N', Integer) { |value| seed = value } }.parse!
  ErxPl011ConsoleUartFuzz.run(seed: seed)
end
