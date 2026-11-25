# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true
# erx-gate: fuzz seeded deadline=300

require 'open3'
require 'optparse'
require 'tmpdir'
require_relative '../lib/erx/fuzz_warm'

# The fuzz target of the code_objects facet's request decoder,
# erx_code_objects_facet:decode/1 (test/erlang/erx_code_objects_facet_fuzz.erl),
# compiled from source and run alone on stock's emulator (ERX_ERL and ERX_ERLC, the
# oracle's), so it needs no hosted build. It runs the sources as they are, then a copy
# of the decoder with each bound removed in turn, a create's size below 2^64 and a
# drop's number below 2^32, each of which must fail: a session could then ask the
# library for an object or a number no field of its call holds.
module ErxCodeObjectsFacetFuzz
  ROOT = File.expand_path('../..', __dir__)
  DECODER = 'erlang/apps/erx_domain/src/erx_code_objects_facet.erl'
  TARGET = 'test/erlang/erx_code_objects_facet_fuzz.erl'
  # Each seeded fault: the decoder's text, which occurs in it once, and its replacement
  # without the bound. test/host/erx_code_objects_facet_test.rb checks at every landing
  # that each text still occurs once, so an edit of the decoder cannot leave this target
  # unable to run.
  Seed = Data.define(:name, :from, :to)
  SEEDS = [
    Seed.new(name: 'a create of a size past 2^64',
             from: 'when is_integer(Size), Size > 0, Size < 1 bsl 64 ->',
             to: 'when is_integer(Size), Size > 0 ->'),
    Seed.new(name: 'a drop of a number past 2^32',
             from: 'when is_integer(Number), Number > 0, Number < 1 bsl 32 ->',
             to: 'when is_integer(Number), Number > 0 ->')
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
    puts 'erx_code_objects_facet:decode/1 takes exactly the requests the interface does, and neither bound removed passes'
  end

  # In a directory of its own, which also takes the crash dump of a failed round.
  def fuzz(decoder_text, seed:)
    Dir.mktmpdir('erx-code-objects-facet-fuzz') do |work|
      decoder_path = File.join(work, 'erx_code_objects_facet.erl')
      File.binwrite(decoder_path, decoder_text)
      Erx::FuzzWarm.compile(work: work, sources: [decoder_path, File.join(ROOT, TARGET)])

      Open3.capture2e('gtimeout', '-k', '10', DEADLINE_SECONDS, ENV.fetch('ERX_ERL'), '-noshell', '-pa', work,
                      '-run', 'erx_code_objects_facet_fuzz', 'run', seed.to_s, '-s', 'init', 'stop',
                      chdir: work, stdin_data: '')
    end
  end
end

if $PROGRAM_NAME == __FILE__
  seed = 1
  OptionParser.new { |flags| flags.on('--seed N', Integer) { |value| seed = value } }.parse!
  ErxCodeObjectsFacetFuzz.run(seed: seed)
end
