# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'open3'
require 'optparse'
require 'tmpdir'
require_relative '../lib/erx/generated'

# The fuzz target of /dev's entry names and ctl writes, erx_devfs_core:find/2 and
# command/1 (test/erlang/erx_devfs_fuzz.erl), compiled from source with the schema and
# text modules they call (the generated ones from build/gen), and run alone on stock's
# emulator (ERX_ERL and ERX_ERLC, the oracle's), so it needs no hosted build. It runs the
# sources as they are, then a copy of erx_devfs_core whose command/1 takes any write that
# starts with "reset", which must fail: "reset now" or "resetx" would then restart a
# driver.
module ErxDevfsFuzz
  ROOT = File.expand_path('../..', __dir__)
  # The generated sources and headers named here are in build/gen.
  Erx::Generated.ensure(root: ROOT)
  CORE = 'erlang/apps/erx_domain/src/erx_devfs_core.erl'
  GENERATED = %w[erlang/apps/erx/src/generated/erx_schema.erl erlang/apps/erx/src/erx_text_tables.erl]
              .map { |source| Erx::Generated.path(source, root: ROOT) }.freeze
  INCLUDE = Erx::Generated.path('erlang/apps/erx/include', root: ROOT)
  SOURCES = %w[erlang/apps/erx/src/erx_text.erl test/erlang/erx_devfs_fuzz.erl].freeze
  EXACT_RESET = '<<"reset\n">> -> {ok, restart};'
  PREFIX_RESET = '<<"reset", _/binary>> -> {ok, restart};'
  DEADLINE_SECONDS = '120'

  module_function

  def run(seed:)
    core = File.binread(File.join(ROOT, CORE))
    raise "no exact reset spelling in #{CORE}" unless core.include?(EXACT_RESET)

    output, status = fuzz(core, seed: seed)
    abort(output) unless status.success? && output.match?(/^fuzz: \d+ rounds ok, \d+ accepted$/)
    output, status = fuzz(core.sub(EXACT_RESET, PREFIX_RESET), seed: seed)
    abort("a write that only starts with reset passed:\n#{output}") if status.success? || !output.include?('command_disagrees')
    puts 'erx_devfs_core reads each /dev name and ctl write in its one spelling, and a prefix of reset does not pass'
  end

  # In a directory of its own, which also takes the crash dump of a failed round.
  def fuzz(core_text, seed:)
    Dir.mktmpdir('erx-devfs-fuzz') do |work|
      core_path = File.join(work, 'erx_devfs_core.erl')
      File.binwrite(core_path, core_text)
      output, status = Open3.capture2e(ENV.fetch('ERX_ERLC'), '-I', INCLUDE, '-o', work, core_path,
                                       *GENERATED, *SOURCES.map { |source| File.join(ROOT, source) }, stdin_data: '')
      raise output unless status.success?

      Open3.capture2e('gtimeout', '-k', '10', DEADLINE_SECONDS, ENV.fetch('ERX_ERL'), '-noshell', '-pa', work,
                      '-run', 'erx_devfs_fuzz', 'run', seed.to_s, '-s', 'init', 'stop',
                      chdir: work, stdin_data: '')
    end
  end
end

if $PROGRAM_NAME == __FILE__
  seed = 1
  OptionParser.new { |flags| flags.on('--seed N', Integer) { |value| seed = value } }.parse!
  ErxDevfsFuzz.run(seed: seed)
end
