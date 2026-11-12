# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'open3'
require 'optparse'
require 'tmpdir'

# The fuzz targets of erx_domain_mints, the domain service's pure core for facets
# configured domains serve (test/erlang/erx_domain_mints_fuzz.erl): report drives it with
# ready reports whose provides are any term a server could send, reply with mint replies
# and acknowledgements from the right and wrong domains and tags. Compiled from source and
# run on stock's emulator (ERX_ERL and ERX_ERLC, the oracle's). Each target runs the core as
# it is, then each copy with a fault the target exists to catch: report, an owner check
# that reads only a mint's creation, so a pid with the server's creation and another
# domain's node is accepted; reply, a reply check that takes any pid as the server's
# facet, and one that refuses the server's honest reply.
module ErxDomainMintsFuzz
  ROOT = File.expand_path('../..', __dir__)
  CORE = 'erlang/apps/erx_domain/src/erx_domain_mints.erl'
  FUZZ = 'test/erlang/erx_domain_mints_fuzz.erl'
  Fault = Data.define(:what, :anchor, :replacement)
  FAULTS = {
    'report' => [Fault.new(what: 'a mint owner check without its node',
                           anchor: 'node(Pid) =:= Node andalso Owner(Pid) =:= Id',
                           replacement: 'is_atom(Node) andalso Owner(Pid) =:= Id'),
                 Fault.new(what: 'an unmarked grant\'s mint that keeps its facet row\'s session',
                           anchor: 'session_limits(Limits, false) -> maps:remove(session, Limits).',
                           replacement: 'session_limits(Limits, false) -> Limits.')],
    'reply' => [Fault.new(what: 'a reply check that takes any facet',
                          anchor: 'is_owned(Facet, {ServerId, Node}, State)',
                          replacement: 'is_atom(Node) orelse State =:= ServerId'),
                Fault.new(what: 'a reply check that refuses the server\'s own facet',
                          anchor: 'is_owned(Facet, {ServerId, Node}, State)',
                          replacement: 'not is_owned(Facet, {ServerId, Node}, State)')]
  }.freeze
  DEADLINE_SECONDS = '300'

  module_function

  def run(target:, seed:)
    faults = FAULTS.fetch(target)
    source = File.binread(File.join(ROOT, CORE))
    faults.each { |fault| raise "no #{fault.anchor} in #{CORE}" unless source.include?(fault.anchor) }

    output, status = fuzz(source, target: target, seed: seed)
    abort(output) unless status.success? && output.match?(/^fuzz: \d+ sequences ok$/)
    puts output
    faults.each do |fault|
      output, status = fuzz(source.sub(fault.anchor, fault.replacement), target: target, seed: seed)
      abort("#{fault.what} passed:\n#{output}") if status.success? || !output.include?('check_failed')
    end
    puts "erx_domain_mints keeps every property over its #{target} inputs, and none of " \
         "#{faults.map(&:what).join(', ')} does"
  end

  # In a directory of its own, removed with whatever a failed sequence left in it.
  def fuzz(core_text, target:, seed:)
    Dir.mktmpdir('erx-domain-mints-fuzz') do |work|
      core_path = File.join(work, File.basename(CORE))
      File.binwrite(core_path, core_text)
      output, status = Open3.capture2e(ENV.fetch('ERX_ERLC'), '-o', work, core_path, File.join(ROOT, FUZZ),
                                       stdin_data: '')
      raise output unless status.success?

      Open3.capture2e('gtimeout', '-k', '10', DEADLINE_SECONDS, ENV.fetch('ERX_ERL'), '-noshell', '-pa', work,
                      '-run', 'erx_domain_mints_fuzz', 'run', target, seed.to_s, '-s', 'init', 'stop',
                      chdir: work, stdin_data: '')
    end
  end
end

if $PROGRAM_NAME == __FILE__
  options = { seed: 1, target: 'report' }
  OptionParser.new do |flags|
    flags.on('--seed N', Integer) { |value| options[:seed] = value }
    flags.on('--target NAME', ErxDomainMintsFuzz::FAULTS.keys) { |value| options[:target] = value }
  end.parse!
  ErxDomainMintsFuzz.run(target: options.fetch(:target), seed: options.fetch(:seed))
end
