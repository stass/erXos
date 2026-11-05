# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'open3'
require 'optparse'
require 'tmpdir'

# The fuzz target of erx_file_remote's path handling: random paths through last_name/1 and
# name lists through names/1 against a model (test/erlang/erx_file_remote_fuzz.erl),
# compiled from source and run on stock's emulator (ERX_ERL and ERX_ERLC, the oracle's).
# It runs the client as it is, then a copy that keeps a path's trailing slashes, which the
# model must catch: that shows the paths reach the trimming and the model checks it.
module ErxFileRemoteFuzz
  ROOT = File.expand_path('../..', __dir__)
  MODULE_SOURCE = File.join(ROOT, 'otp/erts/preloaded/src/erx_file_remote.erl')
  TARGET_SOURCE = File.join(ROOT, 'test/erlang/erx_file_remote_fuzz.erl')
  INCLUDES = %w[otp/lib/kernel/include erlang/apps/erx/include].map { |dir| File.join(ROOT, dir) }.freeze
  TRIMMED = 'Trimmed = trim_slashes(Path, byte_size(Path)),'
  UNTRIMMED = 'Trimmed = Path,'
  DEADLINE_SECONDS = '240'

  module_function

  def run(seed:)
    source = File.binread(MODULE_SOURCE)
    raise "no trimming in #{MODULE_SOURCE}" unless source.scan(TRIMMED).size == 1

    output, status = fuzz(source, seed: seed)
    abort(output) unless status.success? && output.match?(/^fuzz: \d+ paths ok$/)
    output, status = fuzz(source.sub(TRIMMED, UNTRIMMED), seed: seed)
    abort("a client keeping trailing slashes passed:\n#{output}") if status.success? || !output.include?('last_name')
    puts 'erx_file_remote splits every path as the model does, and a client keeping trailing slashes does not'
  end

  # In a directory of its own, which also takes the crash dump of a failed run.
  def fuzz(module_text, seed:)
    Dir.mktmpdir('erx-file-remote-fuzz') do |work|
      module_path = File.join(work, 'erx_file_remote.erl')
      File.binwrite(module_path, module_text)
      output, status = Open3.capture2e(ENV.fetch('ERX_ERLC'), *INCLUDES.flat_map { |dir| ['-I', dir] },
                                       '-o', work, module_path, TARGET_SOURCE, stdin_data: '')
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
