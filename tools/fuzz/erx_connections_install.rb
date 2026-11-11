# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'open3'
require 'optparse'
require 'tmpdir'

# The fuzz target of a domain's connection agent, erx_connections, as the installer of
# facets a configured domain minted for its domain (test/erlang/erx_connections_install_fuzz.erl):
# random installations and other messages in the system connection's envelope, in other
# domains' envelopes and bare, with every registry write and acknowledgement checked
# against a model. Compiled from source and run on stock's emulator (ERX_ERL and ERX_ERLC,
# the oracle's). It runs the agent as it is, then a copy that installs from any domain's
# envelope, which the target must catch.
module ErxConnectionsInstallFuzz
  ROOT = File.expand_path('../..', __dir__)
  AGENT = 'erlang/apps/erx/src/erx_connections.erl'
  FUZZ = 'test/erlang/erx_connections_install_fuzz.erl'
  ENVELOPE = '{erx_origin, SystemId, {erx_facets_install, Tag, Name, Facet}}'
  ANY_ENVELOPE = '{erx_origin, _AnyDomain, {erx_facets_install, Tag, Name, Facet}}'
  DEADLINE_SECONDS = '300'

  module_function

  def run(seed:)
    source = File.binread(File.join(ROOT, AGENT))
    raise "no #{ENVELOPE} in #{AGENT}" unless source.include?(ENVELOPE)

    output, status = fuzz(source, seed: seed)
    abort(output) unless status.success? && output.match?(/^fuzz: \d+ sequences ok$/)
    puts output
    output, status = fuzz(source.sub(ENVELOPE, ANY_ENVELOPE), seed: seed)
    abort("an agent installing from any domain passed:\n#{output}") if status.success? || !output.include?('check_failed')
    puts 'erx_connections installs only from the system connection, acknowledges each installation, ' \
         'and counts the rest, and an agent installing from any domain does not'
  end

  # In a directory of its own, removed with whatever a failed sequence left in it.
  def fuzz(agent_text, seed:)
    Dir.mktmpdir('erx-connections-install-fuzz') do |work|
      agent_path = File.join(work, File.basename(AGENT))
      File.binwrite(agent_path, agent_text)
      output, status = Open3.capture2e(ENV.fetch('ERX_ERLC'), '-o', work, agent_path, File.join(ROOT, FUZZ),
                                       stdin_data: '')
      raise output unless status.success?

      Open3.capture2e('gtimeout', '-k', '10', DEADLINE_SECONDS, ENV.fetch('ERX_ERL'), '-noshell', '-pa', work,
                      '-run', 'erx_connections_install_fuzz', 'run', seed.to_s, '-s', 'init', 'stop',
                      chdir: work, stdin_data: '')
    end
  end
end

if $PROGRAM_NAME == __FILE__
  seed = 1
  OptionParser.new { |flags| flags.on('--seed N', Integer) { |value| seed = value } }.parse!
  ErxConnectionsInstallFuzz.run(seed: seed)
end
