# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true
# erx-gate: fuzz seeded deadline=300

require 'open3'
require 'optparse'
require 'tmpdir'
require_relative '../lib/erx/generated'
require_relative '../lib/erx/fuzz_warm'

# The fuzz target of the login facet's request decoding, erx_login_facet:admit/3 over
# decode/1, and of operation/1, which reads a request through it
# (test/erlang/erx_login_facet_fuzz.erl), compiled from source with the generated ABI
# header it takes its bounds from (build/gen) and run alone on stock's emulator (ERX_ERL
# and ERX_ERLC, the oracle's), so it needs no hosted build. It runs the sources as they
# are, then a copy of erx_login_facet with each seeded fault planted in turn, each of
# which must fail with the property it breaks: a passphrase bound removed, the
# design's seed, would hand the service a request outside the interface; a decode that
# raises on a short request would end the facet with the request in its reason.
module ErxLoginFacetFuzz
  ROOT = File.expand_path('../..', __dir__)
  # The generated header named here is in build/gen.
  Erx::Generated.ensure(root: ROOT)
  FACET = 'erlang/apps/erx_domain/src/erx_login_facet.erl'
  IDENT = 'erlang/apps/erx_domain/src/erx_ident.erl'
  HEADER = 'erlang/apps/erx/include'
  INCLUDE = Erx::Generated.path('erlang/apps/erx/include', root: ROOT)
  TARGET = 'test/erlang/erx_login_facet_fuzz.erl'
  # Each seeded fault: the decoder's text, which occurs in it once, its replacement, and
  # the failure the target must report. test/host/erx_login_test.rb checks at every
  # landing that each text still occurs once, so an edit of the decoder cannot leave this
  # target unable to run.
  Seed = Data.define(:name, :from, :to, :failure)
  SEEDS = [
    Seed.new(name: 'a passphrase bound removed',
             from: 'when ?IS_LOGIN_PASSPHRASE(Passphrase), ?IS_LOGIN_PEER(Peer) ->',
             to: 'when is_binary(Passphrase), ?IS_LOGIN_PEER(Peer) ->',
             failure: 'accepted_out_of_bounds'),
    Seed.new(name: 'a decode that raises on a short request',
             from: "decode(_Request) ->\n    {error, badarg}.",
             to: "decode({_Operation} = Request) ->\n    error({short, Request});\n" \
                 "decode(_Request) ->\n    {error, badarg}.",
             failure: 'admit_raised')
  ].freeze
  DEADLINE_SECONDS = '120'

  module_function

  def run(seed:)
    decoder = File.binread(File.join(ROOT, FACET))
    SEEDS.each { |fault| raise "#{FACET} lacks #{fault.from}" unless decoder.scan(fault.from).size == 1 }

    output, status = fuzz(decoder, seed: seed)
    abort(output) unless status.success? && output.match?(/^fuzz: \d+ rounds ok, \d+ accepted$/)
    SEEDS.each do |fault|
      output, status = fuzz(decoder.sub(fault.from) { fault.to }, seed: seed)
      abort("#{fault.name} passed:\n#{output}") if status.success? || !output.include?(fault.failure)
    end
    puts 'erx_login_facet:admit/3 forwards exactly the requests the interface takes, and each seeded fault fails'
  end

  # In a directory of its own, which also takes the crash dump of a failed round.
  def fuzz(decoder_text, seed:)
    Dir.mktmpdir('erx-login-facet-fuzz') do |work|
      decoder_path = File.join(work, 'erx_login_facet.erl')
      File.binwrite(decoder_path, decoder_text)
      output, status = Open3.capture2e(ENV.fetch('ERX_ERLC'), '-I', INCLUDE, '-I', File.join(ROOT, HEADER), '-o', work, decoder_path,
                                       File.join(ROOT, IDENT), File.join(ROOT, TARGET),
                                       Erx::FuzzWarm::SOURCE, stdin_data: '')
      raise output unless status.success?

      Open3.capture2e('gtimeout', '-k', '10', DEADLINE_SECONDS, ENV.fetch('ERX_ERL'), '-noshell', '-pa', work,
                      '-run', 'erx_login_facet_fuzz', 'run', seed.to_s, '-s', 'init', 'stop',
                      chdir: work, stdin_data: '')
    end
  end
end

if $PROGRAM_NAME == __FILE__
  seed = 1
  OptionParser.new { |flags| flags.on('--seed N', Integer) { |value| seed = value } }.parse!
  ErxLoginFacetFuzz.run(seed: seed)
end
