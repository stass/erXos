# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'open3'
require 'optparse'
require 'tmpdir'

# The fuzz target of the host link's 9P bridge core, erx_hostlink_9p
# (test/erlang/erx_hostlink_9p_fuzz.erl), compiled with the generated codec and grammar
# and run alone on stock's emulator (ERX_ERL and ERX_ERLC, the oracle's). It runs the
# core as it is, then a copy whose fid table admits one fid past the pool, which must
# fail: that shows the rounds reach the bound (docs/design-live.md, "Files between the
# host and the machine").
module ErxHostlink9pFuzz
  ROOT = File.expand_path('../..', __dir__)
  SOURCES = [File.join(ROOT, 'build/gen/otp/erts/preloaded/src/erx_9p_grammar.erl'),
             File.join(ROOT, 'erlang/apps/erx/src/generated/erx_9p.erl')].freeze
  CORE_SOURCE = File.join(ROOT, 'erlang/apps/erx_hostlink/src/erx_hostlink_9p.erl')
  TARGET_SOURCE = File.join(ROOT, 'test/erlang/erx_hostlink_9p_fuzz.erl')
  INCLUDE = File.join(ROOT, 'build/gen/erlang/apps/erx/include')
  POOL_CHECK = 'map_size(Fids) >= Pool -> {error, emfile};'
  NO_POOL_CHECK = 'map_size(Fids) > Pool -> {error, emfile};'
  DEADLINE_SECONDS = '300'

  module_function

  def run(seed:)
    source = File.binread(CORE_SOURCE)
    raise "no pool check in #{CORE_SOURCE}" unless source.include?(POOL_CHECK)

    output, status = fuzz(source, seed: seed)
    abort(output) unless status.success? && output.match?(/^fuzz: \d+ rounds ok$/)
    output, status = fuzz(source.sub(POOL_CHECK, NO_POOL_CHECK), seed: seed)
    abort("a bridge whose pool admits one fid more passed:\n#{output}") if status.success? || !output.include?('out_of_bounds')
    puts 'erx_hostlink_9p keeps its bounds and answers the host in 9P2000.L, and a bridge past its pool does not'
  end

  # In a directory of its own, which also takes the crash dump of a failed round.
  def fuzz(core_text, seed:)
    Dir.mktmpdir('erx-hostlink-9p-fuzz') do |work|
      core_path = File.join(work, 'erx_hostlink_9p.erl')
      File.binwrite(core_path, core_text)
      output, status = Open3.capture2e('gtimeout', '-k', '10', '120', ENV.fetch('ERX_ERLC'), '-I', INCLUDE, '-o', work,
                                       *SOURCES, core_path, TARGET_SOURCE, stdin_data: '')
      raise output unless status.success?

      Open3.capture2e('gtimeout', '-k', '10', DEADLINE_SECONDS, ENV.fetch('ERX_ERL'), '-noshell', '-pa', work,
                      '-run', 'erx_hostlink_9p_fuzz', 'run', seed.to_s, '-s', 'init', 'stop', chdir: work, stdin_data: '')
    end
  end
end

if $PROGRAM_NAME == __FILE__
  seed = 1
  OptionParser.new { |flags| flags.on('--seed N', Integer) { |value| seed = value } }.parse!
  ErxHostlink9pFuzz.run(seed: seed)
end
