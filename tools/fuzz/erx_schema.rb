# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'open3'
require 'optparse'
require 'tmpdir'
require_relative '../lib/erx/generated'

# The fuzz target of erx_schema:resolve_text/1, the reader of the path text /proc and the
# host hand the inspector, and of erx_schema:validate_record/1, which keeps names out of
# records, compiled from the checked-in generated module and run alone on stock's
# emulator (ERX_ERL and ERX_ERLC, the oracle's), so it needs no hosted build. It runs the
# module as it is, then two copies that must fail: one whose name decoding also passes a
# raw ".", which shows the target holds every path to its one spelling, and one whose
# record check overlooks a pid, which shows the target finds a name wherever it is.
module ErxSchemaFuzz
  ROOT = File.expand_path('../..', __dir__)
  # The generated sources and headers named here are in build/gen.
  Erx::Generated.ensure(root: ROOT)
  MODULE_SOURCE = File.join(ROOT, 'build/gen/erlang/apps/erx/src/generated/erx_schema.erl')
  TARGET_SOURCE = File.join(ROOT, 'test/erlang/erx_schema_fuzz.erl')
  PLAIN = 'plain(Byte) -> lists:member(Byte, "_+,:=@-").'
  PLAIN_WITH_DOT = 'plain(Byte) -> lists:member(Byte, "_+,:=@-.").'
  NAME_GUARD = 'holds_name([Term | _Rest]) when is_pid(Term); is_port(Term);'
  NAME_GUARD_WITHOUT_PID = 'holds_name([Term | _Rest]) when is_port(Term);'
  DEADLINE_SECONDS = '120'
  # The target's own verdicts; whichever comes first catches the mutant.
  VERDICTS = %w[disagrees_with_reference second_spelling term_disagrees].freeze
  NAME_VERDICTS = %w[name_not_refused name_accepted].freeze
  PASSED = /^fuzz: \d+ rounds ok, \d+ accepted\nfuzz: \d+ records ok, \d+ accepted, \d+ refused as named$/

  module_function

  def run(seed:)
    source = File.binread(MODULE_SOURCE)
    raise "no plain-byte set in #{MODULE_SOURCE}" unless source.include?(PLAIN)
    raise "no name guard in #{MODULE_SOURCE}" unless source.include?(NAME_GUARD)

    output, status = fuzz(source, seed: seed)
    abort(output) unless status.success? && output.match?(PASSED)
    output, status = fuzz(source.sub(PLAIN, PLAIN_WITH_DOT), seed: seed)
    abort("decoding a raw dot passed:\n#{output}") if status.success? || VERDICTS.none? { |verdict| output.include?(verdict) }
    output, status = fuzz(source.sub(NAME_GUARD, NAME_GUARD_WITHOUT_PID), seed: seed)
    if status.success? || NAME_VERDICTS.none? { |verdict| output.include?(verdict) }
      abort("a record check blind to pids passed:\n#{output}")
    end
    puts 'erx_schema:resolve_text/1 reads each path in its one spelling, and decoding a raw dot does not; ' \
         'erx_schema:validate_record/1 refuses every name, and a check blind to pids does not'
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
