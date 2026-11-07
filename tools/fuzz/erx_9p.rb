# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'open3'
require 'optparse'
require 'tmpdir'
require_relative '../lib/erx/generated'

# The fuzz target of erx_9p, the generated codec of the file protocol's 9P2000.L bytes,
# compiled from the checked-in generated sources (the codec and the grammar it is checked
# against) and run alone on stock's emulator (ERX_ERL and ERX_ERLC, the oracle's). It runs
# the codec as it is, then a copy that skips the msize check, which must fail: that shows
# the oversized rounds reach the check (docs/design-files.md#verification).
module Erx9pFuzz
  ROOT = File.expand_path('../..', __dir__)
  # The generated sources and headers named here are in build/gen.
  Erx::Generated.ensure(root: ROOT)
  CODEC_SOURCE = File.join(ROOT, 'build/gen/erlang/apps/erx/src/generated/erx_9p.erl')
  GRAMMAR_SOURCE = File.join(ROOT, 'build/gen/otp/erts/preloaded/src/erx_9p_grammar.erl')
  TARGET_SOURCE = File.join(ROOT, 'test/erlang/erx_9p_fuzz.erl')
  MSIZE_CHECK = "        <<Size:32/little, _/binary>> when Size > Msize ->\n            {error, msize};\n"
  NO_MSIZE_CHECK = "        <<Size:32/little, _/binary>> when Size > 16#ffffffff ->\n            {error, msize};\n"
  DEADLINE_SECONDS = '300'

  module_function

  def run(seed:)
    source = File.binread(CODEC_SOURCE)
    raise "no msize check in #{CODEC_SOURCE}" unless source.include?(MSIZE_CHECK)

    output, status = fuzz(source, seed: seed)
    abort(output) unless status.success? && output.match?(/^fuzz: \d+ rounds ok$/)
    output, status = fuzz(source.sub(MSIZE_CHECK, NO_MSIZE_CHECK), seed: seed)
    abort("a codec without its msize check passed:\n#{output}") if status.success? || !output.include?('oversized_accepted')
    puts 'erx_9p decodes what 9P2000.L allows and refuses the rest, and a codec without its msize check does not'
  end

  # In a directory of its own, which also takes the crash dump of a failed round.
  def fuzz(codec_text, seed:)
    Dir.mktmpdir('erx-9p-fuzz') do |work|
      codec_path = File.join(work, 'erx_9p.erl')
      File.binwrite(codec_path, codec_text)
      output, status = Open3.capture2e('gtimeout', '-k', '10', '120', ENV.fetch('ERX_ERLC'), '-o', work, codec_path, GRAMMAR_SOURCE, TARGET_SOURCE,
                                       stdin_data: '')
      raise output unless status.success?

      Open3.capture2e('gtimeout', '-k', '10', DEADLINE_SECONDS, ENV.fetch('ERX_ERL'), '-noshell', '-pa', work,
                      '-run', 'erx_9p_fuzz', 'run', seed.to_s, '-s', 'init', 'stop', chdir: work, stdin_data: '')
    end
  end
end

if $PROGRAM_NAME == __FILE__
  seed = 1
  OptionParser.new { |flags| flags.on('--seed N', Integer) { |value| seed = value } }.parse!
  Erx9pFuzz.run(seed: seed)
end
