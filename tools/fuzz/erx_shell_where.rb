# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'open3'
require 'optparse'
require 'tmpdir'
require_relative '../lib/erx/generated'

# The fuzz target of `where`'s predicate parser and evaluator, erx_shell_where
# (test/erlang/erx_shell_where_fuzz.erl), compiled from source with the modules it
# stands on and run on stock's emulator (ERX_ERL and ERX_ERLC, the oracle's). It runs
# the modules as they are, then copies of erx_shell_where, each with one fault the
# target must catch: one that allows 65 levels, which its nestings of 65 catch; one
# whose bound on a predicate is twice 4,096 bytes, which its predicates just over the
# bound catch; one whose `and` forgets an undecided operand, which its reference
# evaluator catches; and one whose `not` binds looser than `and`, which its generated
# trees catch. That shows the target reaches both bounds and checks the three-valued
# logic and the grammar's precedence (docs/design-shell.md, "Verification and testing").
module ErxShellWhereFuzz
  ROOT = File.expand_path('../..', __dir__)
  # The generated sources and headers named here are in build/gen.
  Erx::Generated.ensure(root: ROOT)
  SOURCES = %w[build/gen/erlang/apps/erx/src/erx_text_tables.erl erlang/apps/erx/src/erx_text.erl
               erlang/apps/erx_shell/src/erx_render.erl
               erlang/apps/erx_shell/src/erx_shell_glob.erl].map { |path| File.join(ROOT, path) }.freeze
  WHERE_SOURCE = File.join(ROOT, 'erlang/apps/erx_shell/src/erx_shell_where.erl')
  TARGET_SOURCE = File.join(ROOT, 'test/erlang/erx_shell_where_fuzz.erl')
  DEADLINE_SECONDS = '300'

  Fault = Data.define(:what, :anchor, :replacement, :markers)

  FAULTS = [
    Fault.new(what: 'a parser allowing 65 levels', anchor: '-define(MAX_DEPTH, 64).',
              replacement: '-define(MAX_DEPTH, 65).', markers: %w[too_deep_accepted]),
    Fault.new(what: 'a parser whose bound is 8,192 bytes',
              anchor: 'parse(Source) when byte_size(Source) > ?MAX_SOURCE ->',
              replacement: 'parse(Source) when byte_size(Source) > 2 * ?MAX_SOURCE ->',
              markers: %w[over_size_accepted over_size_not_refused]),
    Fault.new(what: 'an `and` that forgets an undecided operand',
              anchor: 'undecided -> all(Preds, Record, undecided)',
              replacement: 'undecided -> all(Preds, Record, Truth)', markers: %w[wrong_truth status_became_value]),
    Fault.new(what: 'a `not` that binds looser than `and`',
              anchor: '{Factor, Rest} = factor(Tokens, enter(Depth, At)),',
              replacement: '{Factor, Rest} = term(Tokens, enter(Depth, At)),', markers: %w[generated_round_trip])
  ].freeze

  module_function

  def run(seed:)
    text = File.binread(WHERE_SOURCE)
    output, status = fuzz(text, seed: seed)
    abort(output) unless status.success? && output.match?(/^fuzz: \d+ inputs ok$/)
    FAULTS.each do |fault|
      raise "no #{fault.anchor} in erx_shell_where" unless text.include?(fault.anchor)

      output, status = fuzz(text.sub(fault.anchor, fault.replacement), seed: seed)
      abort("#{fault.what} passed:\n#{output}") if output.match?(/^fuzz: \d+ inputs ok$/) || fault.markers.none? { |marker| output.include?(marker) }
    end
    puts 'erx_shell_where parses or diagnoses every predicate within its bounds and agrees with its reference, ' \
         'and none of a parser allowing 65 levels, one with twice the bound, an `and` that forgets undecided ' \
         'or a `not` binding looser than `and` does'
  end

  # In a directory of its own, which also takes the crash dump of a failed run.
  def fuzz(where_text, seed:)
    Dir.mktmpdir('erx-shell-where-fuzz') do |work|
      where = File.join(work, 'erx_shell_where.erl').tap { |path| File.binwrite(path, where_text) }
      output, status = Open3.capture2e(ENV.fetch('ERX_ERLC'), '-o', work, *SOURCES, where, TARGET_SOURCE, stdin_data: '')
      raise output unless status.success?

      Open3.capture2e('gtimeout', '-k', '10', DEADLINE_SECONDS, ENV.fetch('ERX_ERL'), '-noshell', '-pa', work,
                      '-run', 'erx_shell_where_fuzz', 'run', seed.to_s, '-s', 'init', 'stop',
                      chdir: work, stdin_data: '')
    end
  end
end

if $PROGRAM_NAME == __FILE__
  seed = 1
  OptionParser.new { |flags| flags.on('--seed N', Integer) { |value| seed = value } }.parse!
  ErxShellWhereFuzz.run(seed: seed)
end
