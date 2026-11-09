# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'open3'
require 'optparse'
require 'tmpdir'
require_relative '../lib/erx/generated'

# The fuzz target of erx_present:parse/2 and erx_present:parse_uri/1, the readers of a
# presentation's text and link, compiled from the generated modules and run alone on
# stock's emulator (ERX_ERL and ERX_ERLC, the oracle's), so it needs no hosted build. It
# runs the module as it is, then a copy whose link reader also takes an escape of a byte
# the link keeps, which must fail: that shows the target holds every value to its one
# spelling.
module ErxPresentFuzz
  ROOT = File.expand_path('../..', __dir__)
  # The generated sources named here are in build/gen.
  Erx::Generated.ensure(root: ROOT)
  PRESENT = Erx::Generated.path('erlang/apps/erx/src/generated/erx_present.erl', root: ROOT)
  SCHEMA = Erx::Generated.path('erlang/apps/erx/src/generated/erx_schema.erl', root: ROOT)
  TARGET_SOURCE = File.join(ROOT, 'test/erlang/erx_present_fuzz.erl')
  ESCAPE_CHECK = "        false ?= uri_plain(Byte),\n"
  DEADLINE_SECONDS = '120'
  # The target's own verdicts; whichever comes first catches the mutant.
  VERDICTS = %w[second_spelling disagrees_with_reference].freeze

  module_function

  def run(seed:)
    source = File.binread(PRESENT)
    raise "no escape check in #{PRESENT}" unless source.include?(ESCAPE_CHECK)

    output, status = fuzz(source, seed: seed)
    abort(output) unless status.success? && output.match?(/^fuzz: \d+ rounds ok, \d+ accepted$/)
    output, status = fuzz(source.sub(ESCAPE_CHECK, ''), seed: seed)
    abort("reading an escaped kept byte passed:\n#{output}") if status.success? || VERDICTS.none? { |verdict| output.include?(verdict) }
    puts 'erx_present reads each value in its one spelling, and reading an escaped kept byte does not'
  end

  # In a directory of its own, which also takes the crash dump of a failed round.
  def fuzz(module_text, seed:)
    Dir.mktmpdir('erx-present-fuzz') do |work|
      module_path = File.join(work, 'erx_present.erl')
      File.binwrite(module_path, module_text)
      output, status = Open3.capture2e(ENV.fetch('ERX_ERLC'), '-o', work, SCHEMA, module_path, TARGET_SOURCE,
                                       stdin_data: '')
      raise output unless status.success?

      Open3.capture2e('gtimeout', '-k', '10', DEADLINE_SECONDS, ENV.fetch('ERX_ERL'), '-noshell', '-pa', work,
                      '-run', 'erx_present_fuzz', 'run', seed.to_s, '-s', 'init', 'stop',
                      chdir: work, stdin_data: '')
    end
  end
end

if $PROGRAM_NAME == __FILE__
  seed = 1
  OptionParser.new { |flags| flags.on('--seed N', Integer) { |value| seed = value } }.parse!
  ErxPresentFuzz.run(seed: seed)
end
