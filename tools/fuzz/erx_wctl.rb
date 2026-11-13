# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'open3'
require 'optparse'
require 'tmpdir'

# The fuzz target of erx_wctl:parse/1, the parser of a window's wctl file, whose bytes
# come from a client (docs/design-display.md, "Verification and testing"). It is compiled
# from source and run alone on stock's emulator (ERX_ERL and ERX_ERLC, the oracle's), as
# the module is and then as two copies that each drop one check, which must fail: one
# without the 1,024-byte bound on a line, one without the top of the coordinate range.
# That shows the reference and the inputs reach both checks.
module ErxWctlFuzz
  ROOT = File.expand_path('../..', __dir__)
  MODULE_SOURCE = File.join(ROOT, 'erlang/apps/erx_display/src/erx_wctl.erl')
  TARGET_SOURCE = File.join(ROOT, 'test/erlang/erx_wctl_fuzz.erl')
  SEEDED = {
    'the 1,024-byte bound' => ['byte_size(Bytes) =< ?MAX_LINE', 'byte_size(Bytes) >= 0'],
    'the coordinate range' => ['Sign * Magnitude =< ?MAX_COORD', 'is_integer(Magnitude)']
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
    puts "erx_wctl:parse/1 agrees with its reference, and parsers without #{SEEDED.keys.join(' or ')} do not"
  end

  # In a directory of its own, which also takes the crash dump of a failed round.
  def fuzz(module_text, seed:)
    Dir.mktmpdir('erx-wctl-fuzz') do |work|
      module_path = File.join(work, 'erx_wctl.erl')
      File.binwrite(module_path, module_text)
      output, status = Open3.capture2e('gtimeout', '-k', '10', DEADLINE_SECONDS, ENV.fetch('ERX_ERLC'), '-o', work, module_path, TARGET_SOURCE, stdin_data: '')
      raise output unless status.success?

      Open3.capture2e('gtimeout', '-k', '10', DEADLINE_SECONDS, ENV.fetch('ERX_ERL'), '-noshell', '-pa', work,
                      '-run', 'erx_wctl_fuzz', 'run', seed.to_s, '-s', 'init', 'stop', chdir: work, stdin_data: '')
    end
  end
end

if $PROGRAM_NAME == __FILE__
  seed = 1
  OptionParser.new { |flags| flags.on('--seed N', Integer) { |value| seed = value } }.parse!
  ErxWctlFuzz.run(seed: seed)
end
