# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'open3'
require 'optparse'
require 'tmpdir'
require_relative '../lib/erx/generated'

# The fuzz target of the log facet's request decoder, erx_log_facet:decode/1
# (test/erlang/erx_log_facet_fuzz.erl), compiled from source with the generated ABI
# header it takes its bounds from (build/gen) and run alone on stock's emulator (ERX_ERL
# and ERX_ERLC, the oracle's), so it needs no hosted build. It runs the sources as they
# are, then a copy of erx_log_facet with each bound removed in turn, the 16-record walk
# and the 4,096-byte text, each of which must fail: a holder could then hand the
# service a batch or a text of any size.
module ErxLogFacetFuzz
  ROOT = File.expand_path('../..', __dir__)
  # The generated header named here is in build/gen.
  Erx::Generated.ensure(root: ROOT)
  DECODER = 'erlang/apps/erx/src/erx_log_facet.erl'
  INCLUDE = Erx::Generated.path('erlang/apps/erx/include', root: ROOT)
  TARGET = 'test/erlang/erx_log_facet_fuzz.erl'
  # Each seeded fault: the decoder's text, which occurs in it once, and its replacement
  # without the bound. test/host/erx_log_facet_test.rb checks at every landing that each
  # text still occurs once, so an edit of the decoder cannot leave this target unable to run.
  Seed = Data.define(:name, :from, :to)
  SEEDS = [
    Seed.new(name: 'a write past 16 records',
             from: 'records([Record | Rest], Count) when Count < ?ERX_LOG_WRITE_MAX ->',
             to: 'records([Record | Rest], Count) when is_integer(Count) ->'),
    Seed.new(name: 'a text past 4,096 bytes',
             from: 'when is_binary(Text), byte_size(Text) =< ?ERX_LOG_WRITE_TEXT_MAX ->',
             to: 'when is_binary(Text) ->')
  ].freeze
  DEADLINE_SECONDS = '120'

  module_function

  def run(seed:)
    decoder = File.binread(File.join(ROOT, DECODER))
    SEEDS.each { |fault| raise "#{DECODER} lacks #{fault.from}" unless decoder.scan(fault.from).size == 1 }

    output, status = fuzz(decoder, seed: seed)
    abort(output) unless status.success? && output.match?(/^fuzz: \d+ rounds ok, \d+ accepted$/)
    SEEDS.each do |fault|
      output, status = fuzz(decoder.sub(fault.from, fault.to), seed: seed)
      abort("#{fault.name} passed:\n#{output}") if status.success? || !output.include?('accepted_out_of_bounds')
    end
    puts 'erx_log_facet:decode/1 takes exactly the writes the interface does, and neither bound removed passes'
  end

  # In a directory of its own, which also takes the crash dump of a failed round.
  def fuzz(decoder_text, seed:)
    Dir.mktmpdir('erx-log-facet-fuzz') do |work|
      decoder_path = File.join(work, 'erx_log_facet.erl')
      File.binwrite(decoder_path, decoder_text)
      output, status = Open3.capture2e(ENV.fetch('ERX_ERLC'), '-I', INCLUDE, '-o', work, decoder_path,
                                       File.join(ROOT, TARGET), stdin_data: '')
      raise output unless status.success?

      Open3.capture2e('gtimeout', '-k', '10', DEADLINE_SECONDS, ENV.fetch('ERX_ERL'), '-noshell', '-pa', work,
                      '-run', 'erx_log_facet_fuzz', 'run', seed.to_s, '-s', 'init', 'stop',
                      chdir: work, stdin_data: '')
    end
  end
end

if $PROGRAM_NAME == __FILE__
  seed = 1
  OptionParser.new { |flags| flags.on('--seed N', Integer) { |value| seed = value } }.parse!
  ErxLogFacetFuzz.run(seed: seed)
end
