#!/usr/bin/env ruby
# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

# Runs test/erlang/erx_net_admit_fuzz.erl, the fuzz target of the network stack's admission
# of messages from the other domain (docs/design-network-stack.md, "Untrusted input"), for
# one target, against the sources as they are and against a copy with the target's seeded
# fault, which must fail it:
#   admit  erx_net_admit:request/2, with the comparison of the reply alias's domain dropped;
#   sock   erx_sock_admit:answer/3, with the interface name's bound of 15 bytes dropped.

require 'open3'
require 'optparse'
require 'tmpdir'
require_relative '../lib/erx/generated'

module ErxNetAdmitFuzz
  ROOT = File.expand_path('../..', __dir__)
  TARGET_SOURCE = File.join(ROOT, 'test/erlang/erx_net_admit_fuzz.erl')
  DEADLINE_SECONDS = '300'
  PASSED = /^fuzz: \d+ inputs ok$/

  Fault = Data.define(:what, :source, :anchor, :replacement, :marker)

  ADMIT = 'erlang/apps/erx_net/src/erx_net_admit.erl'
  SOCK = 'erlang/apps/erx_net_client/src/erx_sock_admit.erl'
  INET = 'erlang/apps/erx_net_client/src/erx_inet.erl'

  FAULTS = {
    'admit' => Fault.new(what: 'a grant that does not compare the reply alias\'s domain', source: ADMIT,
                         anchor: 'domain(Pid) =:= Grantee andalso domain(Alias) =:= Grantee',
                         replacement: 'domain(Pid) =:= Grantee',
                         marker: 'request2_admitted_bad'),
    'sock' => Fault.new(what: 'an interfaces check without the name bound', source: SOCK,
                        anchor: 'byte_size(Name) >= 1, byte_size(Name) =< ?IFNAMSIZ,',
                        replacement: 'byte_size(Name) >= 1,', marker: 'answer_admitted_bad')
  }.freeze

  # The sources each target compiles beside the fuzz module: the checks under test, and what
  # they call (the sock target's resolver answers are checked by erx_inet).
  SOURCES = {
    'admit' => [ADMIT],
    'sock' => [SOCK, INET]
  }.freeze

  module_function

  def run(target:, seed:)
    fault = FAULTS.fetch(target)
    Erx::Generated.ensure(root: ROOT)
    texts = SOURCES.fetch(target).to_h { |path| [path, File.binread(File.join(ROOT, path))] }
    output, status = fuzz(texts, target: target, seed: seed)
    abort(output) unless status.success? && output.match?(PASSED)
    raise "no #{fault.anchor} in #{fault.source}" unless texts.fetch(fault.source).include?(fault.anchor)

    faulty = texts.merge(fault.source => texts.fetch(fault.source).sub(fault.anchor) { fault.replacement })
    output, = fuzz(faulty, target: target, seed: seed)
    abort("#{fault.what} passed:\n#{output}") if output.match?(PASSED) || !output.include?(fault.marker)
    puts "erx_net_admit #{target}: every input passed, and #{fault.what} failed with #{fault.marker}"
  end

  # In a directory of its own, which also takes the crash dump of a failed run.
  def fuzz(texts, target:, seed:)
    Dir.mktmpdir('erx-net-admit-fuzz') do |work|
      paths = texts.map { |path, text| File.join(work, File.basename(path)).tap { |copy| File.binwrite(copy, text) } }
      output, status = Open3.capture2e(ENV.fetch('ERX_ERLC'), '-o', work, *paths, TARGET_SOURCE, stdin_data: '')
      raise output unless status.success?

      Open3.capture2e('gtimeout', '-k', '10', DEADLINE_SECONDS, ENV.fetch('ERX_ERL'), '-noshell', '-pa', work,
                      '-run', 'erx_net_admit_fuzz', 'run', target, seed.to_s, '-s', 'init', 'stop',
                      chdir: work, stdin_data: '')
    end
  end
end

if $PROGRAM_NAME == __FILE__
  target = nil
  seed = 1
  OptionParser.new do |flags|
    flags.on('--target NAME', ErxNetAdmitFuzz::FAULTS.keys) { |value| target = value }
    flags.on('--seed N', Integer) { |value| seed = value }
  end.parse!
  abort("usage: #{$PROGRAM_NAME} --target #{ErxNetAdmitFuzz::FAULTS.keys.join('|')} [--seed N]") unless target
  ErxNetAdmitFuzz.run(target: target, seed: seed)
end
