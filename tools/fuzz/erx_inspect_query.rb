# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'open3'
require 'optparse'
require 'tmpdir'
require_relative '../lib/erx/generated'

# The fuzz target of the inspect facet's request decoder, erx_inspect_query:decode/1
# (test/erlang/erx_inspect_query_fuzz.erl), compiled from source with the generated
# schema it reads the declared paths from (build/gen) and run alone on stock's emulator
# (ERX_ERL and ERX_ERLC, the oracle's), so it needs no hosted build. It runs the sources
# as they are, then a copy of erx_inspect_query whose path walk has lost its 16-segment
# bound, which must fail: a holder could then hand the worker a path of any length.
module ErxInspectQueryFuzz
  ROOT = File.expand_path('../..', __dir__)
  # The generated sources and headers named here are in build/gen.
  Erx::Generated.ensure(root: ROOT)
  DECODER = 'erlang/apps/erx/src/erx_inspect_query.erl'
  GENERATED = [Erx::Generated.path('erlang/apps/erx/src/generated/erx_schema.erl', root: ROOT)].freeze
  INCLUDE = Erx::Generated.path('erlang/apps/erx/include', root: ROOT)
  TARGET = 'test/erlang/erx_inspect_query_fuzz.erl'
  LENGTH_BOUND = 'path([Segment | Rest], Count, Literals) when Count < ?ERX_INSPECT_PATH_MAX ->'
  NO_LENGTH_BOUND = 'path([Segment | Rest], Count, Literals) when is_integer(Count) ->'
  DEADLINE_SECONDS = '120'

  module_function

  def run(seed:)
    decoder = File.binread(File.join(ROOT, DECODER))
    raise "no path-length bound in #{DECODER}" unless decoder.include?(LENGTH_BOUND)

    output, status = fuzz(decoder, seed: seed)
    abort(output) unless status.success? && output.match?(/^fuzz: \d+ rounds ok, \d+ accepted$/)
    output, status = fuzz(decoder.sub(LENGTH_BOUND, NO_LENGTH_BOUND), seed: seed)
    abort("a path past 16 segments passed:\n#{output}") if status.success? || !output.include?('accepted_out_of_bounds')
    puts 'erx_inspect_query:decode/1 takes exactly the requests within the Bounds, and a path past 16 segments does not pass'
  end

  # In a directory of its own, which also takes the crash dump of a failed round.
  def fuzz(decoder_text, seed:)
    Dir.mktmpdir('erx-inspect-query-fuzz') do |work|
      decoder_path = File.join(work, 'erx_inspect_query.erl')
      File.binwrite(decoder_path, decoder_text)
      output, status = Open3.capture2e(ENV.fetch('ERX_ERLC'), '-I', INCLUDE, '-o', work, decoder_path,
                                       *GENERATED, File.join(ROOT, TARGET), stdin_data: '')
      raise output unless status.success?

      Open3.capture2e('gtimeout', '-k', '10', DEADLINE_SECONDS, ENV.fetch('ERX_ERL'), '-noshell', '-pa', work,
                      '-run', 'erx_inspect_query_fuzz', 'run', seed.to_s, '-s', 'init', 'stop',
                      chdir: work, stdin_data: '')
    end
  end
end

if $PROGRAM_NAME == __FILE__
  seed = 1
  OptionParser.new { |flags| flags.on('--seed N', Integer) { |value| seed = value } }.parse!
  ErxInspectQueryFuzz.run(seed: seed)
end
