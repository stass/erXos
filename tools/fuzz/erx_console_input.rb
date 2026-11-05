# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'fileutils'
require 'open3'
require 'optparse'
require 'tmpdir'

# The fuzz target of erx_console:input/2, the one parser of console input bytes, compiled
# from source and run alone on stock's emulator (ERX_ERL and ERX_ERLC, the oracle's), so it
# needs no hosted build and stock's own terminal driver still starts under -noshell. It runs
# the module as it is, then a copy whose latin-1 branch answers wrong, which must fail: that
# shows the reference reads that branch.
module ErxConsoleInputFuzz
  ROOT = File.expand_path('../..', __dir__)
  MODULE_SOURCE = File.join(ROOT, 'otp/lib/kernel/src/erx_console.erl')
  TARGET_SOURCE = File.join(ROOT, 'test/erlang/erx_console_input_fuzz.erl')
  LATIN1_BRANCH = 'data(latin1(<<Bad>>))'
  WRONG_BRANCH = 'data(<<(Bad band 16#7f)>>)'
  DEADLINE_SECONDS = '120'

  module_function

  def run(seed:)
    source = File.binread(MODULE_SOURCE)
    raise "no latin-1 branch in #{MODULE_SOURCE}" unless source.include?(LATIN1_BRANCH)

    output, status = fuzz(source, seed: seed)
    abort(output) unless status.success? && output.match?(/^fuzz: \d+ rounds ok$/)
    output, status = fuzz(source.sub(LATIN1_BRANCH, WRONG_BRANCH), seed: seed)
    abort("the wrong latin-1 branch passed:\n#{output}") if status.success? || !output.include?('disagrees_with_reference')
    puts 'erx_console:input/2 agrees with its reference, and a wrong latin-1 branch does not'
  end

  # In a directory of its own, which also takes the crash dump of a failed round.
  def fuzz(module_text, seed:)
    Dir.mktmpdir('erx-console-fuzz') do |work|
      module_path = File.join(work, 'erx_console.erl')
      File.binwrite(module_path, module_text)
      output, status = Open3.capture2e(ENV.fetch('ERX_ERLC'), '-o', work, module_path, TARGET_SOURCE, stdin_data: '')
      raise output unless status.success?

      Open3.capture2e('gtimeout', '-k', '10', DEADLINE_SECONDS, ENV.fetch('ERX_ERL'), '-noshell', '-pa', work,
                      '-run', 'erx_console_input_fuzz', 'run', seed.to_s, '-s', 'init', 'stop', chdir: work, stdin_data: '')
    end
  end
end

if $PROGRAM_NAME == __FILE__
  seed = 1
  OptionParser.new { |flags| flags.on('--seed N', Integer) { |value| seed = value } }.parse!
  ErxConsoleInputFuzz.run(seed: seed)
end
