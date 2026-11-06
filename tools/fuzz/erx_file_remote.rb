# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'open3'
require 'optparse'
require 'tmpdir'

# The fuzz target of erx_file_remote's request function: random batches of walks, stats
# and mkdirs through refused/2 against a model (test/erlang/erx_file_remote_fuzz.erl),
# compiled from source with the grammar and run on stock's emulator (ERX_ERL and
# ERX_ERLC, the oracle's). It runs the client as it is, then a copy whose request function
# lets ".." through, which the model must catch: that shows the walks reach the refusal
# and the model checks it.
module ErxFileRemoteFuzz
  ROOT = File.expand_path('../..', __dir__)
  MODULE_SOURCE = File.join(ROOT, 'otp/erts/preloaded/src/erx_file_remote.erl')
  GRAMMAR_SOURCE = File.join(ROOT, 'otp/erts/preloaded/src/erx_9p_grammar.erl')
  TARGET_SOURCE = File.join(ROOT, 'test/erlang/erx_file_remote_fuzz.erl')
  INCLUDES = %w[otp/lib/kernel/include erlang/apps/erx/include].map { |dir| File.join(ROOT, dir) }.freeze
  REFUSAL = "dot_dot({walk, _, _, [<<\"..\">> | _]}) -> true;\n"
  DEADLINE_SECONDS = '240'

  module_function

  def run(seed:)
    source = File.binread(MODULE_SOURCE)
    raise "no refusal of \"..\" in #{MODULE_SOURCE}" unless source.scan(REFUSAL).size == 1

    output, status = fuzz(source, seed: seed)
    abort(output) unless status.success? && output.match?(/^fuzz: \d+ batches ok$/)
    output, status = fuzz(source.sub(REFUSAL, ''), seed: seed)
    abort("a client sending \"..\" passed:\n#{output}") if status.success? || !output.include?('refused')
    puts 'erx_file_remote refuses every request the model refuses, and a client sending ".." does not'
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
