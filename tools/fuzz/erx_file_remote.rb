# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'open3'
require 'optparse'
require 'tmpdir'

# The fuzz target of erx_file_remote's request function and walk reader: random batches of walks, stats
# and mkdirs through refused/2 against a model (test/erlang/erx_file_remote_fuzz.erl),
# and random server replies to walks through walk_reply/2 against a model of how a reply
# is read, compiled from source with the grammar and run on stock's emulator (ERX_ERL and
# ERX_ERLC, the oracle's). It runs the client as it is, then each copy of MUTANTS, which
# the model must catch: one whose request function lets ".." through, one whose walk
# reader takes a qid after a file as a name walked, and one that forgets the kinds of the
# chunks before. That shows the inputs reach each check and the model checks them.
module ErxFileRemoteFuzz
  ROOT = File.expand_path('../..', __dir__)
  MODULE_SOURCE = File.join(ROOT, 'otp/erts/preloaded/src/erx_file_remote.erl')
  GRAMMAR_SOURCE = File.join(ROOT, 'otp/erts/preloaded/src/erx_9p_grammar.erl')
  TARGET_SOURCE = File.join(ROOT, 'test/erlang/erx_file_remote_fuzz.erl')
  INCLUDES = %w[otp/lib/kernel/include erlang/apps/erx/include].map { |dir| File.join(ROOT, dir) }.freeze
  Mutant = Data.define(:what, :from, :to, :caught_by)
  MUTANTS = [
    Mutant.new(what: 'a client sending ".."', from: "dot_dot({walk, _, _, [<<\"..\">> | _]}) -> true;\n",
               to: '', caught_by: 'refused'),
    Mutant.new(what: 'a reader walking past a file', from: "        {_, [_ | _]} -> past_a_file\n",
               to: "        {Kind, _} -> kinds(Qids, [Kind | Kinds])\n", caught_by: 'walk_reply'),
    Mutant.new(what: 'a reader forgetting earlier chunks',
               from: "chunk_end(whole, [directory | _] = Passed, Walks, Replies) -> walk_reply(Walks, Replies, Passed);\n",
               to: "chunk_end(whole, [directory | _], Walks, Replies) -> walk_reply(Walks, Replies, []);\n",
               caught_by: 'walk_reply')
  ].freeze
  DEADLINE_SECONDS = '240'

  module_function

  def run(seed:)
    source = File.binread(MODULE_SOURCE)
    MUTANTS.each { |mutant| raise "no line for #{mutant.what} in #{MODULE_SOURCE}" unless source.scan(mutant.from).size == 1 }

    output, status = fuzz(source, seed: seed)
    abort(output) unless status.success? && output.match?(/^fuzz: \d+ batches ok\nfuzz: \d+ walk replies ok$/)
    MUTANTS.each do |mutant|
      output, status = fuzz(source.sub(mutant.from, mutant.to), seed: seed)
      abort("#{mutant.what} passed:\n#{output}") if status.success? || !output.include?(mutant.caught_by)
    end
    puts 'erx_file_remote refuses every request and reads every walk reply as the model does, ' \
         'and no copy in MUTANTS does'
  end

  # In a directory of its own, which also takes the crash dump of a failed run.
  def fuzz(module_text, seed:)
    Dir.mktmpdir('erx-file-remote-fuzz') do |work|
      module_path = File.join(work, 'erx_file_remote.erl')
      File.binwrite(module_path, module_text)
      output, status = Open3.capture2e(ENV.fetch('ERX_ERLC'), *INCLUDES.flat_map { |dir| ['-I', dir] },
                                       '-o', work, module_path, GRAMMAR_SOURCE, TARGET_SOURCE, stdin_data: '')
      raise output unless status.success?

      Open3.capture2e('gtimeout', '-k', '10', DEADLINE_SECONDS, ENV.fetch('ERX_ERL'), '-noshell', '-pa', work,
                      '-run', 'erx_file_remote_fuzz', 'run', seed.to_s, '-s', 'init', 'stop', chdir: work, stdin_data: '')
    end
  end
end

if $PROGRAM_NAME == __FILE__
  seed = 1
  OptionParser.new { |flags| flags.on('--seed N', Integer) { |value| seed = value } }.parse!
  ErxFileRemoteFuzz.run(seed: seed)
end
