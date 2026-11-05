# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'open3'
require 'optparse'
require 'tmpdir'

# The fuzz target of erx_9p_grammar, the generated decoder of the file protocol's terms,
# compiled from the checked-in generated source and run alone on stock's emulator (ERX_ERL
# and ERX_ERLC, the oracle's). It runs the module as it is, then a copy whose name bound
# admits 256 bytes, which must fail: that shows the reference reads the name bound.
module Erx9pGrammarFuzz
  ROOT = File.expand_path('../..', __dir__)
  MODULE_SOURCE = File.join(ROOT, 'erlang/apps/erx/src/generated/erx_9p_grammar.erl')
  TARGET_SOURCE = File.join(ROOT, 'test/erlang/erx_9p_grammar_fuzz.erl')
  NAME_BOUND = "is_name(Value) ->\n    is_binary(Value)\n        andalso byte_size(Value) =< ?NAME_MAX\n"
  WRONG_BOUND = "is_name(Value) ->\n    is_binary(Value)\n        andalso byte_size(Value) =< ?NAME_MAX + 1\n"
  DEADLINE_SECONDS = '300'

  module_function

  def run(seed:)
    source = File.binread(MODULE_SOURCE)
    raise "no name bound in #{MODULE_SOURCE}" unless source.include?(NAME_BOUND)

    output, status = fuzz(source, seed: seed)
    abort(output) unless status.success? && output.match?(/^fuzz: \d+ rounds ok$/)
    output, status = fuzz(source.sub(NAME_BOUND, WRONG_BOUND), seed: seed)
    abort("the wrong name bound passed:\n#{output}") if status.success? || !output.include?('disagrees_with_reference')
    puts 'erx_9p_grammar refuses what its reference refuses, and a wrong name bound does not'
  end

  # In a directory of its own, which also takes the crash dump of a failed round.
  def fuzz(module_text, seed:)
    Dir.mktmpdir('erx-9p-grammar-fuzz') do |work|
      module_path = File.join(work, 'erx_9p_grammar.erl')
      File.binwrite(module_path, module_text)
      output, status = Open3.capture2e(ENV.fetch('ERX_ERLC'), '-o', work, module_path, TARGET_SOURCE, stdin_data: '')
      raise output unless status.success?

      Open3.capture2e('gtimeout', '-k', '10', DEADLINE_SECONDS, ENV.fetch('ERX_ERL'), '-noshell', '-pa', work,
                      '-run', 'erx_9p_grammar_fuzz', 'run', seed.to_s, '-s', 'init', 'stop', chdir: work, stdin_data: '')
    end
  end
end

if $PROGRAM_NAME == __FILE__
  seed = 1
  OptionParser.new { |flags| flags.on('--seed N', Integer) { |value| seed = value } }.parse!
  Erx9pGrammarFuzz.run(seed: seed)
end
