# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'open3'
require 'optparse'
require 'tmpdir'
require_relative '../lib/erx/generated'

# The fuzz target of /proc's entry names, erx_procfs_core:child/2 and walk/3
# (test/erlang/erx_procfs_fuzz.erl), compiled from source with the schema, the inspector
# and the renderer they call (the generated schema and text tables from build/gen), and
# run alone on stock's emulator (ERX_ERL and ERX_ERLC, the oracle's), so it needs no
# hosted build. It runs the sources as they are, then a copy of erx_procfs_core whose
# child/2 lets a name hold "/", which must fail: a name "/cpus" at the root would then
# read as cpus in a second spelling.
module ErxProcfsFuzz
  ROOT = File.expand_path('../..', __dir__)
  # The generated sources and headers named here are in build/gen.
  Erx::Generated.ensure(root: ROOT)
  CORE = 'erlang/apps/erx_files/src/erx_procfs_core.erl'
  GENERATED = %w[erlang/apps/erx/src/generated/erx_schema.erl erlang/apps/erx/src/erx_text_tables.erl]
              .map { |source| Erx::Generated.path(source, root: ROOT) }.freeze
  INCLUDE = Erx::Generated.path('erlang/apps/erx/include', root: ROOT)
  SOURCES = %w[
    erlang/apps/erx/src/erx_text.erl
    erlang/apps/erx/src/erx_object_info.erl
    erlang/apps/erx/src/erx_kernel_records.erl
    erlang/apps/erx/src/erx_process_records.erl
    erlang/apps/erx/src/erx_inspector.erl
    erlang/apps/erx_shell/src/erx_render.erl
    test/erlang/erx_procfs_fuzz.erl
  ].freeze
  SLASH_CHECK = 'case binary:match(Name, <<"/">>) of'
  NO_SLASH_CHECK = 'case nomatch of'
  DEADLINE_SECONDS = '120'
  VERDICTS = %w[second_spelling not_one_level_below disagrees_with_writer walk_disagrees].freeze

  module_function

  def run(seed:)
    core = File.binread(File.join(ROOT, CORE))
    raise "no slash check in #{CORE}" unless core.include?(SLASH_CHECK)

    output, status = fuzz(core, seed: seed)
    abort(output) unless status.success? && output.match?(/^fuzz: \d+ rounds ok, \d+ accepted$/)
    output, status = fuzz(core.sub(SLASH_CHECK, NO_SLASH_CHECK), seed: seed)
    abort("a name holding a slash passed:\n#{output}") if status.success? || VERDICTS.none? { |verdict| output.include?(verdict) }
    puts 'erx_procfs_core:child/2 reads each entry name in its one spelling, and a name holding "/" does not pass'
  end

  # In a directory of its own, which also takes the crash dump of a failed round.
  def fuzz(core_text, seed:)
    Dir.mktmpdir('erx-procfs-fuzz') do |work|
      core_path = File.join(work, 'erx_procfs_core.erl')
      File.binwrite(core_path, core_text)
      output, status = Open3.capture2e(ENV.fetch('ERX_ERLC'), '-I', INCLUDE,
                                       '-o', work, core_path,
                                       *GENERATED, *SOURCES.map { |source| File.join(ROOT, source) }, stdin_data: '')
      raise output unless status.success?

      Open3.capture2e('gtimeout', '-k', '10', DEADLINE_SECONDS, ENV.fetch('ERX_ERL'), '-noshell', '-pa', work,
                      '-run', 'erx_procfs_fuzz', 'run', seed.to_s, '-s', 'init', 'stop',
                      chdir: work, stdin_data: '')
    end
  end
end

if $PROGRAM_NAME == __FILE__
  seed = 1
  OptionParser.new { |flags| flags.on('--seed N', Integer) { |value| seed = value } }.parse!
  ErxProcfsFuzz.run(seed: seed)
end
