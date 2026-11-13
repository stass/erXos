# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'open3'
require 'optparse'
require 'tmpdir'

# The fuzz target of erx_mini_uart:console_uart/1, the parse of the console's device words
# that the boot information carries to init's arguments on the Raspberry Pi 4, compiled from
# source and run alone on stock's emulator (ERX_ERL and ERX_ERLC, the oracle's), so it needs
# no hosted build. It runs the module as it is, then each seeded copy of MUTANTS, which must
# fail: a copy that takes the first of several entries shows the reference reads
# duplicates, one that accepts any clock shows it refuses an entry with a clock, which the
# mini UART's row never carries, and one that takes a shared line for a direct one shows it
# holds the entry to its line's mark.
module ErxMiniUartConsoleUartFuzz
  ROOT = File.expand_path('../..', __dir__)
  MODULE_SOURCE = File.join(ROOT, 'erlang/apps/erx_uart/src/erx_mini_uart.erl')
  TARGET_SOURCE = File.join(ROOT, 'test/erlang/erx_mini_uart_console_uart_fuzz.erl')
  # What each seeded copy says, the text it replaces and the text it plants.
  MUTANTS = {
    'taking the first of several entries' => ['[[Base, Size, Line, Mark, Clock | _]] ->', '[[Base, Size, Line, Mark, Clock | _] | _] ->'],
    'accepting any clock' => ['{{ok, B}, {ok, S}, {ok, L}, {ok, 0}, {ok, Sharing}} ->',
                              '{{ok, B}, {ok, S}, {ok, L}, {ok, _}, {ok, Sharing}} ->'],
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
    puts "erx_mini_uart:console_uart/1 agrees with its reference, and no seeded copy does (#{MUTANTS.keys.join('; ')})"
  end

  # In a directory of its own, which also takes the crash dump of a failed round.
  def fuzz(module_text, seed:)
    Dir.mktmpdir('erx-mini-uart-fuzz') do |work|
      module_path = File.join(work, 'erx_mini_uart.erl')
      File.binwrite(module_path, module_text)
      output, status = Open3.capture2e(ENV.fetch('ERX_ERLC'), '-o', work, module_path, TARGET_SOURCE, stdin_data: '')
      raise output unless status.success?

      Open3.capture2e('gtimeout', '-k', '10', DEADLINE_SECONDS, ENV.fetch('ERX_ERL'), '-noshell', '-pa', work,
                      '-run', 'erx_mini_uart_console_uart_fuzz', 'run', seed.to_s, '-s', 'init', 'stop',
                      chdir: work, stdin_data: '')
    end
  end
end

if $PROGRAM_NAME == __FILE__
  seed = 1
  OptionParser.new { |flags| flags.on('--seed N', Integer) { |value| seed = value } }.parse!
  ErxMiniUartConsoleUartFuzz.run(seed: seed)
end
