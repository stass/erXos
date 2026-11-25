# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true
# erx-gate: fuzz seeded deadline=300

require 'open3'
require 'optparse'
require 'tmpdir'
require_relative '../lib/erx/generated'

# The fuzz target of the clock facet's request decoder, erx_clock_facet:decode/1, and of
# operation/1, which reads a request through it (test/erlang/erx_clock_facet_fuzz.erl),
# compiled from source with the generated ABI header it takes its bounds from
# (build/gen) and run alone on stock's emulator (ERX_ERL and ERX_ERLC, the oracle's), so
# it needs no hosted build. It runs the sources as they are, then a copy of
# erx_clock_facet with each seeded fault planted in turn, each of which must fail with
# the property it breaks: a stratum of 0 accepted, the design's seed, would hand the
# clock service a sample outside the interface; a decoder that raises on a short request
# would end the facet on a grantee's malformed call.
module ErxClockFacetFuzz
  ROOT = File.expand_path('../..', __dir__)
  # The generated header named here is in build/gen.
  Erx::Generated.ensure(root: ROOT)
  DECODER = 'erlang/apps/erx/src/erx_clock_facet.erl'
  INCLUDE = Erx::Generated.path('erlang/apps/erx/include', root: ROOT)
  TARGET = 'test/erlang/erx_clock_facet_fuzz.erl'
  # The atom-count warm-up every target of this kind shares.
  WARM = File.join(ROOT, 'test/erlang/erx_fuzz_warm.erl')
  # Each seeded fault: the decoder's text, which occurs in it once, its replacement, and
  # the failure the target must report. test/host/erx_clock_test.rb checks at every
  # landing that each text still occurs once, so an edit of the decoder cannot leave this
  # target unable to run.
  Seed = Data.define(:name, :from, :to, :failure)
  SEEDS = [
    Seed.new(name: 'a stratum of 0 accepted',
             from: 'Stratum >= 1, Stratum =< 15', to: 'Stratum >= 0, Stratum =< 15',
             failure: 'accepted_out_of_bounds'),
    Seed.new(name: 'a decode that raises on a short request',
             from: "decode(_Request) ->\n    {error, badarg}.",
             to: "decode({_Operation} = Request) ->\n    error({short, Request});\n" \
                 "decode(_Request) ->\n    {error, badarg}.",
             failure: 'decode_raised')
  ].freeze
  DEADLINE_SECONDS = '120'

  module_function

  def run(seed:)
    decoder = File.binread(File.join(ROOT, DECODER))
    SEEDS.each { |fault| raise "#{DECODER} lacks #{fault.from}" unless decoder.scan(fault.from).size == 1 }

    output, status = fuzz(decoder, seed: seed)
    abort(output) unless status.success? && output.match?(/^fuzz: \d+ rounds ok, \d+ accepted$/)
    SEEDS.each do |fault|
      output, status = fuzz(decoder.sub(fault.from) { fault.to }, seed: seed)
      abort("#{fault.name} passed:\n#{output}") if status.success? || !output.include?(fault.failure)
    end
    puts 'erx_clock_facet:decode/1 takes exactly the requests the interface does, and each seeded fault fails'
  end

  # In a directory of its own, which also takes the crash dump of a failed round.
  def fuzz(decoder_text, seed:)
    Dir.mktmpdir('erx-clock-facet-fuzz') do |work|
      decoder_path = File.join(work, 'erx_clock_facet.erl')
      File.binwrite(decoder_path, decoder_text)
      output, status = Open3.capture2e(ENV.fetch('ERX_ERLC'), '-I', INCLUDE, '-o', work, decoder_path,
                                       File.join(ROOT, TARGET), WARM, stdin_data: '')
      raise output unless status.success?

      Open3.capture2e('gtimeout', '-k', '10', DEADLINE_SECONDS, ENV.fetch('ERX_ERL'), '-noshell', '-pa', work,
                      '-run', 'erx_clock_facet_fuzz', 'run', seed.to_s, '-s', 'init', 'stop',
                      chdir: work, stdin_data: '')
    end
  end
end

if $PROGRAM_NAME == __FILE__
  seed = 1
  OptionParser.new { |flags| flags.on('--seed N', Integer) { |value| seed = value } }.parse!
  ErxClockFacetFuzz.run(seed: seed)
end
