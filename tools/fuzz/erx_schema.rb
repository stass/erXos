# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'open3'
require 'optparse'
require 'tmpdir'

# The fuzz target of erx_schema:resolve_text/1, the reader of the path text /proc and the
# host hand the inspector, compiled from the checked-in generated module and run alone on
# stock's emulator (ERX_ERL and ERX_ERLC, the oracle's), so it needs no hosted build. It
# runs the module as it is, then a copy whose name decoding also passes a raw ".", which
# must fail: that shows the target holds every path to its one spelling.
module ErxSchemaFuzz
  ROOT = File.expand_path('../..', __dir__)
  MODULE_SOURCE = File.join(ROOT, 'erlang/apps/erx/src/generated/erx_schema.erl')
  TARGET_SOURCE = File.join(ROOT, 'test/erlang/erx_schema_fuzz.erl')
  PLAIN = 'plain(Byte) -> lists:member(Byte, "_+,:=@-").'
  PLAIN_WITH_DOT = 'plain(Byte) -> lists:member(Byte, "_+,:=@-.").'
  DEADLINE_SECONDS = '120'
  # The target's own verdicts; whichever comes first catches the mutant.
  VERDICTS = %w[disagrees_with_reference second_spelling term_disagrees].freeze

  module_function

  def run(seed:)
    source = File.binread(MODULE_SOURCE)
    raise "no plain-byte set in #{MODULE_SOURCE}" unless source.include?(PLAIN)

    output, status = fuzz(source, seed: seed)
    abort(output) unless status.success? && output.match?(/^fuzz: \d+ rounds ok, \d+ accepted$/)
    output, status = fuzz(source.sub(PLAIN, PLAIN_WITH_DOT), seed: seed)
    abort("decoding a raw dot passed:\n#{output}") if status.success? || VERDICTS.none? { |verdict| output.include?(verdict) }
    puts 'erx_schema:resolve_text/1 reads each path in its one spelling, and decoding a raw dot does not'
  end

  # In a directory of its own, which also takes the crash dump of a failed round.
  def fuzz(module_text, seed:)
    Dir.mktmpdir('erx-schema-fuzz') do |work|
      module_path = File.join(work, 'erx_schema.erl')
      File.binwrite(module_path, module_text)
      output, status = Open3.capture2e(ENV.fetch('ERX_ERLC'), '-o', work, module_path, TARGET_SOURCE, stdin_data: '')
      raise output unless status.success?

      Open3.capture2e('gtimeout', '-k', '10', DEADLINE_SECONDS, ENV.fetch('ERX_ERL'), '-noshell', '-pa', work,
                      '-run', 'erx_schema_fuzz', 'run', seed.to_s, '-s', 'init', 'stop',
                      chdir: work, stdin_data: '')
    end
  end
end

if $PROGRAM_NAME == __FILE__
  seed = 1
  OptionParser.new { |flags| flags.on('--seed N', Integer) { |value| seed = value } }.parse!
  ErxSchemaFuzz.run(seed: seed)
end
