# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true
# erx-gate: fuzz seeded deadline=900

require 'open3'
require 'optparse'
require 'tmpdir'
require_relative '../lib/erx/generated'
require_relative '../lib/erx/fsimg'
require_relative '../../test/fixtures/fat_volumes'

# The fuzz target of the FAT checker, erx_fat_check (test/erlang/erx_fat_check_fuzz.erl,
# docs/design-fsck-fat.md "Fuzz target"), compiled from source with the FAT server's
# library and run alone on stock's emulator (ERX_ERL and ERX_ERLC, the oracle's), over
# the volumes erx_fat_check_tests lays out and those FatVolumes has fsimg write. It
# runs the checker as it is, then a copy whose phase 1 does not end a chain that links
# to a cluster linked to before, which must fail: a walk then follows a loop and the
# round passes its deadline or its work bound.
module ErxFatCheckFuzz
  ROOT = File.expand_path('../..', __dir__)
  CORE = 'erlang/apps/erx_fat/src/erx_fat_check.erl'
  SOURCES = %w[erlang/apps/erx_fat/src/erx_fat.erl erlang/apps/erx_fat/src/erx_fat_alloc.erl
               erlang/apps/erx_fat/src/erx_fat_read.erl erlang/apps/erx_fat/src/erx_fat_name.erl
               erlang/apps/erx_fat/src/erx_fat_entry.erl erlang/apps/erx_fat/src/erx_fat_plan.erl
               test/erlang/erx_fat_damage.erl
               test/erlang/erx_fat_check_tests.erl test/erlang/erx_fat_check_fuzz.erl].freeze
  # The case table erx_fat_name reads, which the build generates.
  CASE = 'erlang/apps/erx_fat/src/erx_fat_case.erl'
  CHECKED = '                true -> linked(finding(St, {crossed, Cluster, Next}), Cluster, mask(St#st.type))'
  UNCHECKED = '                true -> St'
  DEADLINE_SECONDS = '600'
  VERDICTS = %w[hang work_bound].freeze

  module_function

  def run(seed:)
    Erx::Generated.ensure(root: ROOT)
    core = File.binread(File.join(ROOT, CORE))
    raise "no cross-link cut in #{CORE}" unless core.scan(CHECKED).size == 1

    Dir.mktmpdir('erx-fat-check-volumes') do |volumes|
      FatVolumes.write(volumes, root: ROOT)
      output, status = fuzz(core, seed: seed, volumes: volumes)
      abort(output) unless status.success? && output.match?(/^fuzz: \d+ rounds ok$/)
      output, status = fuzz(core.sub(CHECKED, UNCHECKED), seed: seed, volumes: volumes)
      if status.success? || VERDICTS.none? { |verdict| output.include?(verdict) }
        abort("a checker that keeps cross-links passed:\n#{output}")
      end
    end
    puts 'erx_fat_check ends, stays within its heap and reads only its volume, and the copy that keeps cross-links does not'
  end

  # In a directory of its own, which also takes the volume of a failed round.
  def fuzz(core_text, seed:, volumes:)
    Dir.mktmpdir('erx-fat-check-fuzz') do |work|
      core_path = File.join(work, File.basename(CORE))
      File.binwrite(core_path, core_text)
      include = Erx::Generated.path('erlang/apps/erx/include', root: ROOT)
      output, status = Open3.capture2e(ENV.fetch('ERX_ERLC'), '-I', include, '-I', File.join(ROOT, File.dirname(CORE)),
                                       '-o', work, core_path, *SOURCES.map { |source| File.join(ROOT, source) },
                                       Erx::Generated.path(CASE, root: ROOT), stdin_data: '')
      raise output unless status.success?

      Open3.capture2e('gtimeout', '-k', '10', DEADLINE_SECONDS, ENV.fetch('ERX_ERL'), '-noshell', '-pa', work,
                      '-run', 'erx_fat_check_fuzz', 'run', seed.to_s, volumes, '-s', 'init', 'stop',
                      chdir: work, stdin_data: '')
    end
  end
end

if $PROGRAM_NAME == __FILE__
  seed = 1
  OptionParser.new { |flags| flags.on('--seed N', Integer) { |value| seed = value } }.parse!
  ErxFatCheckFuzz.run(seed: seed)
end
