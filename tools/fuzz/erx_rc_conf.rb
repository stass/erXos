# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'open3'
require 'optparse'
require 'tmpdir'
require_relative '../lib/erx/generated'

# The fuzz target of rc.conf, erx_start_table:parse_rc_conf/1 with merge/3 and set/3
# over what it reads (test/erlang/erx_rc_conf_fuzz.erl), compiled from source and run
# alone on stock's emulator (ERX_ERL and ERX_ERLC, the oracle's), so it needs no hosted
# build. It runs the sources as they are, then a copy of erx_start_table without the
# 64 KiB bound, which must fail: a file past the bound would then be read.
module ErxRcConfFuzz
  ROOT = File.expand_path('../..', __dir__)
  CORE = 'erlang/apps/erx_starter/src/erx_start_table.erl'
  # erx_ident, the identifier rule the core reads names with.
  IDENT = 'erlang/apps/erx_domain/src/erx_ident.erl'
  FUZZ = 'test/erlang/erx_rc_conf_fuzz.erl'
  BOUND = '-define(MAX_RC_CONF, 65536).'
  NO_BOUND = '-define(MAX_RC_CONF, 1 bsl 30).'
  DEADLINE_SECONDS = '120'
  VERDICT = 'accepted_over_bound'

  module_function

  def run(seed:)
    Erx::Generated.ensure(root: ROOT)
    core = File.binread(File.join(ROOT, CORE))
    raise "no bound in #{CORE}" unless core.scan(BOUND).size == 1

    output, status = fuzz(core, seed: seed)
    abort(output) unless status.success? && output.match?(/^fuzz: \d+ rounds ok, \d+ [a-z ]+$/)
    output, status = fuzz(core.sub(BOUND, NO_BOUND), seed: seed)
    abort("an input past the bound passed:\n#{output}") if status.success? || !output.include?(VERDICT)
    puts 'erx_start_table reads rc.conf within its 64 KiB bound, and a file past it does not pass'
  end

  # In a directory of its own, which also takes the crash dump of a failed round.
  def fuzz(core_text, seed:)
    Dir.mktmpdir('erx-rc-conf-fuzz') do |work|
      core_path = File.join(work, File.basename(CORE))
      File.binwrite(core_path, core_text)
      sources = [core_path, *[IDENT, FUZZ].map { |source| File.join(ROOT, source) }]
      include = Erx::Generated.path('erlang/apps/erx/include', root: ROOT)
      output, status = Open3.capture2e(ENV.fetch('ERX_ERLC'), '-I', include, '-o', work, *sources, stdin_data: '')
      raise output unless status.success?

      Open3.capture2e('gtimeout', '-k', '10', DEADLINE_SECONDS, ENV.fetch('ERX_ERL'), '-noshell', '-pa', work,
                      '-run', 'erx_rc_conf_fuzz', 'run', seed.to_s, '-s', 'init', 'stop',
                      chdir: work, stdin_data: '')
    end
  end
end

if $PROGRAM_NAME == __FILE__
  seed = 1
  OptionParser.new { |flags| flags.on('--seed N', Integer) { |value| seed = value } }.parse!
  ErxRcConfFuzz.run(seed: seed)
end
