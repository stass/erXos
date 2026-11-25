# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true
# erx-gate: fuzz seeded deadline=300

require 'open3'
require 'optparse'
require 'tmpdir'
require_relative '../lib/erx/generated'
require_relative '../lib/erx/fuzz_warm'

# The fuzz target of the ble facet's admission, erx_ble_facet:admit/3
# (test/erlang/erx_ble_facet_fuzz.erl), compiled from source and run alone on stock's
# emulator (ERX_ERL and ERX_ERLC, the oracle's), so it needs no hosted build. It runs the
# sources as they are, then a copy of erx_ble_facet with each seeded fault planted in
# turn, each of which must fail with the property it breaks: a reply's answer past the
# Application Error range admitted would be answered ok and reach the phone as Unlikely
# Error, where the grantee should hear badarg; a dropped service check would let a
# grantee handle another app's service; a request decoder without its last clause would
# end the facet on a grantee's malformed call.
module ErxBleFacetFuzz
  ROOT = File.expand_path('../..', __dir__)
  FACET = 'erlang/apps/erx_bt/src/erx_ble_facet.erl'
  TARGET = 'test/erlang/erx_ble_facet_fuzz.erl'
  # The generated header named here is in build/gen.
  Erx::Generated.ensure(root: ROOT)
  INCLUDE = Erx::Generated.path('erlang/apps/erx/include', root: ROOT)
  # Each seeded fault: the facet's text, which occurs in it once, its replacement, and
  # the failure the target must report. test/host/erx_ble_facet_test.rb checks at every
  # landing that each text still occurs once, so an edit of the facet cannot leave this
  # target unable to run.
  Seed = Data.define(:name, :from, :to, :failure)
  SEEDS = [
    Seed.new(name: "a reply's answer past the Application Error range admitted",
             from: 'Code =< ?ERX_ATT_APPLICATION_ERROR_MAX ->', to: 'Code =< 16#FF ->',
             failure: 'should_refuse_badarg'),
    Seed.new(name: 'the service check dropped',
             from: 'forward(lists:member(Service, Services), Request, Caller, Grant)',
             to: 'forward(true, Request, Caller, Grant)',
             failure: 'should_refuse_not_granted'),
    Seed.new(name: 'a request decoder that raises on another shape',
             from: "    end;\nnamed(_Request) ->\n    error.\n", to: "    end.\n",
             failure: 'admit_raised')
  ].freeze
  DEADLINE_SECONDS = '120'

  module_function

  def run(seed:)
    facet = File.binread(File.join(ROOT, FACET))
    SEEDS.each { |fault| raise "#{FACET} lacks #{fault.from}" unless facet.scan(fault.from).size == 1 }

    output, status = fuzz(facet, seed: seed)
    abort(output) unless status.success? && output.match?(/^fuzz: \d+ rounds ok, \d+ accepted$/)
    SEEDS.each do |fault|
      output, status = fuzz(facet.sub(fault.from) { fault.to }, seed: seed)
      abort("#{fault.name} passed:\n#{output}") if status.success? || !output.include?(fault.failure)
    end
    puts 'erx_ble_facet:admit/3 admits exactly the requests the interface does, and each seeded fault fails'
  end

  # In a directory of its own, which also takes the crash dump of a failed round.
  def fuzz(facet_text, seed:)
    Dir.mktmpdir('erx-ble-facet-fuzz') do |work|
      facet_path = File.join(work, 'erx_ble_facet.erl')
      File.binwrite(facet_path, facet_text)
      Erx::FuzzWarm.compile(work: work, sources: [facet_path, File.join(ROOT, TARGET)], include: INCLUDE)

      Open3.capture2e('gtimeout', '-k', '10', DEADLINE_SECONDS, ENV.fetch('ERX_ERL'), '-noshell', '-pa', work,
                      '-run', 'erx_ble_facet_fuzz', 'run', seed.to_s, '-s', 'init', 'stop',
                      chdir: work, stdin_data: '')
    end
  end
end

if $PROGRAM_NAME == __FILE__
  seed = 1
  OptionParser.new { |flags| flags.on('--seed N', Integer) { |value| seed = value } }.parse!
  ErxBleFacetFuzz.run(seed: seed)
end
