# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'open3'
require 'optparse'
require 'tmpdir'

# The fuzz target of erx_pl011:console_uart/1, the parse of the console's device words that
# the boot information carries to init's arguments, compiled from source and run alone on
# stock's emulator (ERX_ERL and ERX_ERLC, the oracle's), so it needs no hosted build. It runs
# the module as it is, then a copy that takes the first of several entries, which must fail:
# that shows the reference reads duplicates.
module ErxPl011ConsoleUartFuzz
  ROOT = File.expand_path('../..', __dir__)
  MODULE_SOURCE = File.join(ROOT, 'otp/lib/kernel/src/erx_pl011.erl')
  TARGET_SOURCE = File.join(ROOT, 'test/erlang/erx_pl011_console_uart_fuzz.erl')
  ONE_ENTRY = '[[Base, Size, Line | _]] ->'
  FIRST_OF_SEVERAL = '[[Base, Size, Line | _] | _] ->'
  DEADLINE_SECONDS = '120'

  module_function

  def run(seed:)
    source = File.binread(MODULE_SOURCE)
    raise "no one-entry clause in #{MODULE_SOURCE}" unless source.include?(ONE_ENTRY)

    output, status = fuzz(source, seed: seed)
    abort(output) unless status.success? && output.match?(/^fuzz: \d+ rounds ok, \d+ accepted$/)
    output, status = fuzz(source.sub(ONE_ENTRY, FIRST_OF_SEVERAL), seed: seed)
    abort("taking the first of several entries passed:\n#{output}") if status.success? ||
                                                                         !output.include?('disagrees_with_reference')
    puts 'erx_pl011:console_uart/1 agrees with its reference, and taking the first of several entries does not'
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
