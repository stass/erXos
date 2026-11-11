# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'open3'
require 'optparse'
require 'tmpdir'
require_relative '../lib/erx/generated'

# The fuzz target of erx_prog_grammar, the generated grammar of the program protocol's
# frames, compiled from the generated source and run alone on stock's emulator (ERX_ERL
# and ERX_ERLC, the oracle's). It runs the module as it is, then a copy whose cwd bound
# admits one byte more, which must fail: that shows the target judges cwd against a
# reference of its own.
module ErxProgGrammarFuzz
  ROOT = File.expand_path('../..', __dir__)
  # The generated sources named here are in build/gen.
  Erx::Generated.ensure(root: ROOT)
  MODULE_SOURCE = File.join(ROOT, 'build/gen/otp/erts/preloaded/src/erx_prog_grammar.erl')
  TARGET_SOURCE = File.join(ROOT, 'test/erlang/erx_prog_grammar_fuzz.erl')
  CWD_BOUND = 'text(V, ?PROG_PATH_MAX, [utf8, nul, path], cwd)'
  WRONG_BOUND = 'text(V, ?PROG_PATH_MAX + 1, [utf8, nul, path], cwd)'
  DEADLINE_SECONDS = '300'

  module_function

  def run(seed:)
    source = File.binread(MODULE_SOURCE)
    raise "no cwd bound in #{MODULE_SOURCE}" unless source.include?(CWD_BOUND)

    output, status = fuzz(source, seed: seed)
    abort(output) unless status.success? && output.match?(/^fuzz: \d+ rounds ok$/)
    output, status = fuzz(source.sub(CWD_BOUND, WRONG_BOUND), seed: seed)
    abort("the wrong cwd bound passed:\n#{output}") if status.success? || !output.include?('disagrees_with_reference')
    puts 'erx_prog_grammar judges cwd as its reference does, and a wrong cwd bound does not'
  end

  # In a directory of its own, which also takes the crash dump of a failed round.
  def fuzz(module_text, seed:)
    Dir.mktmpdir('erx-prog-grammar-fuzz') do |work|
      module_path = File.join(work, 'erx_prog_grammar.erl')
      File.binwrite(module_path, module_text)
      output, status = Open3.capture2e(ENV.fetch('ERX_ERLC'), '-o', work, module_path, TARGET_SOURCE, stdin_data: '')
      raise output unless status.success?

      Open3.capture2e('gtimeout', '-k', '10', DEADLINE_SECONDS, ENV.fetch('ERX_ERL'), '-noshell', '-pa', work,
                      '-run', 'erx_prog_grammar_fuzz', 'run', seed.to_s, '-s', 'init', 'stop', chdir: work,
                      stdin_data: '')
    end
  end
end

if $PROGRAM_NAME == __FILE__
  seed = 1
  OptionParser.new { |flags| flags.on('--seed N', Integer) { |value| seed = value } }.parse!
  ErxProgGrammarFuzz.run(seed: seed)
end
