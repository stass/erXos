# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true
# erx-gate: fuzz seeded deadline=600

require 'open3'
require 'optparse'
require 'tmpdir'
require_relative '../lib/erx/generated'
require_relative '../lib/erx/fuzz_warm'
require_relative '../../test/fixtures/fat_record_volume'

# The fuzz target of the record volume's reader, erx_fat_read:root_file/3
# (test/erlang/erx_fat_read_fuzz.erl, docs/design-ssh.md "Verification"), compiled from
# source and run alone on stock's emulator (ERX_ERL and ERX_ERLC, the oracle's), so it
# needs no hosted build, over the volumes FatRecordVolume writes as its seeds. It runs
# the reader as it is, then a copy that follows a FAT link without checking that it
# names a cluster of the data area, which must fail: a mutated link then has the reader
# ask for a sector past the partition.
module ErxFatReadFuzz
  ROOT = File.expand_path('../..', __dir__)
  CORE = 'erlang/apps/erx_fat/src/erx_fat_read.erl'
  FUZZ = 'test/erlang/erx_fat_read_fuzz.erl'
  CHECKED = 'Cluster >= 2 andalso Cluster < Clusters + 2 orelse fail(does_not_read),'
  UNCHECKED = 'Clusters > 0,'
  DEADLINE_SECONDS = '300'
  VERDICT = 'raised'

  module_function

  def run(seed:)
    Erx::Generated.ensure(root: ROOT)
    core = File.binread(File.join(ROOT, CORE))
    raise "no range check on a link in #{CORE}" unless core.scan(CHECKED).size == 1

    Dir.mktmpdir('erx-fat-read-volumes') do |volumes|
      FatRecordVolume.write_cases(volumes)
      output, status = fuzz(core, seed: seed, volumes: volumes)
      abort(output) unless status.success? && output.match?(/^fuzz: \d+ rounds ok, \d+ accepted$/)
      output, status = fuzz(core.sub(CHECKED, UNCHECKED), seed: seed, volumes: volumes)
      abort("a link followed without its range checked passed:\n#{output}") if status.success? || !output.include?(VERDICT)
    end
    puts 'erx_fat_read reads only clusters of the data area, and the unchecked copy does not pass'
  end

  # In a directory of its own, which also takes the crash dump of a failed round.
  def fuzz(core_text, seed:, volumes:)
    Dir.mktmpdir('erx-fat-read-fuzz') do |work|
      core_path = File.join(work, File.basename(CORE))
      File.binwrite(core_path, core_text)
      include = Erx::Generated.path('erlang/apps/erx/include', root: ROOT)
      output, status = Open3.capture2e(ENV.fetch('ERX_ERLC'), '-I', include, '-o', work, core_path,
                                       File.join(ROOT, FUZZ), Erx::FuzzWarm::SOURCE, stdin_data: '')
      raise output unless status.success?

      Open3.capture2e('gtimeout', '-k', '10', DEADLINE_SECONDS, ENV.fetch('ERX_ERL'), '-noshell', '-pa', work,
                      '-run', 'erx_fat_read_fuzz', 'run', seed.to_s, volumes, '-s', 'init', 'stop',
                      chdir: work, stdin_data: '')
    end
  end
end

if $PROGRAM_NAME == __FILE__
  seed = 1
  OptionParser.new { |flags| flags.on('--seed N', Integer) { |value| seed = value } }.parse!
  ErxFatReadFuzz.run(seed: seed)
end
