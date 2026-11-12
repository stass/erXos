# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'open3'
require 'optparse'
require 'tmpdir'

# The fuzz target of the apps tree's ctl file, erx_start_table:parse_ctl/1
# (test/erlang/erx_apps_ctl_fuzz.erl), compiled from source and run alone on stock's
# emulator (ERX_ERL and ERX_ERLC, the oracle's), so it needs no hosted build. It runs
# the sources as they are, then a copy of erx_start_table without the 4,096-byte bound
# on a write, which must fail: a longer write would then be read as a command.
module ErxAppsCtlFuzz
  ROOT = File.expand_path('../..', __dir__)
  CORE = 'erlang/apps/erx_starter/src/erx_start_table.erl'
  # erx_ident, the identifier rule the core reads names with.
  IDENT = 'erlang/apps/erx_domain/src/erx_ident.erl'
  FUZZ = 'test/erlang/erx_apps_ctl_fuzz.erl'
  BOUND = '-define(MAX_CTL, 4096).'
  NO_BOUND = '-define(MAX_CTL, 1 bsl 30).'
  DEADLINE_SECONDS = '120'
  VERDICT = 'accepted_over_bound'

  module_function

  def run(seed:)
    core = File.binread(File.join(ROOT, CORE))
    raise "no bound in #{CORE}" unless core.scan(BOUND).size == 1

    output, status = fuzz(core, seed: seed)
    abort(output) unless status.success? && output.match?(/^fuzz: \d+ rounds ok, \d+ [a-z ]+$/)
    output, status = fuzz(core.sub(BOUND, NO_BOUND), seed: seed)
    abort("an input past the bound passed:\n#{output}") if status.success? || !output.include?(VERDICT)
    puts 'erx_start_table reads one ctl write of at most 4,096 bytes, and a longer one does not pass'
  end

  # In a directory of its own, which also takes the crash dump of a failed round.
  def fuzz(core_text, seed:)
    Dir.mktmpdir('erx-apps-ctl-fuzz') do |work|
      core_path = File.join(work, File.basename(CORE))
      File.binwrite(core_path, core_text)
      sources = [core_path, *[IDENT, FUZZ].map { |source| File.join(ROOT, source) }]
      output, status = Open3.capture2e(ENV.fetch('ERX_ERLC'), '-o', work, *sources, stdin_data: '')
      raise output unless status.success?

      Open3.capture2e('gtimeout', '-k', '10', DEADLINE_SECONDS, ENV.fetch('ERX_ERL'), '-noshell', '-pa', work,
                      '-run', 'erx_apps_ctl_fuzz', 'run', seed.to_s, '-s', 'init', 'stop',
                      chdir: work, stdin_data: '')
    end
  end
end

if $PROGRAM_NAME == __FILE__
  seed = 1
  OptionParser.new { |flags| flags.on('--seed N', Integer) { |value| seed = value } }.parse!
  ErxAppsCtlFuzz.run(seed: seed)
end
