# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true
# erx-gate: fuzz seeded deadline=900

require 'open3'
require 'optparse'
require 'tmpdir'
require_relative '../lib/erx/fsimg'
require_relative '../lib/erx/generated'
require_relative '../../test/fixtures/fat_volumes'

# The fuzz target of the FAT server's allocator, erx_fat_alloc
# (test/erlang/erx_fat_alloc_fuzz.erl, docs/design-storage.md "Removable media: FAT"),
# compiled from source with erx_fat's mount and the allocator's suite, whose image
# helpers it shares, and run alone on stock's emulator (ERX_ERL and ERX_ERLC, the
# oracle's), so it needs no hosted build, over the volumes FatVolumes has fsimg write
# as its seeds, with fsimg's verify its oracle. It runs the allocator as it is, then a
# copy that follows a FAT link without checking that it names a cluster of the data
# area, which must fail: a mutated link then has the allocator read a sector past
# the first FAT.
module ErxFatAllocFuzz
  ROOT = File.expand_path('../..', __dir__)
  CORE = 'erlang/apps/erx_fat/src/erx_fat_alloc.erl'
  SOURCES = %w[erlang/apps/erx_fat/src/erx_fat.erl erlang/apps/erx_fat/src/erx_fat_read.erl
               test/erlang/erx_fat_alloc_tests.erl test/erlang/erx_fat_alloc_fuzz.erl].freeze
  CHECKED = 'when is_integer(Value), Value >= 2, Value < Clusters + 2 ->'
  UNCHECKED = 'when is_integer(Value), Clusters > 0 ->'
  DEADLINE_SECONDS = '600'
  VERDICT = 'read_outside'

  module_function

  def run(seed:)
    Erx::Generated.ensure(root: ROOT)
    core = File.binread(File.join(ROOT, CORE))
    raise "no range check on a link in #{CORE}" unless core.scan(CHECKED).size == 1

    Dir.mktmpdir('erx-fat-alloc-volumes') do |volumes|
      FatVolumes.write(volumes, root: ROOT)
      output, status = fuzz(core, seed: seed, volumes: volumes)
      abort(output) unless status.success? && output.match?(/^fuzz: \d+ rounds ok, \d+ verified$/)
      puts output[/^fuzz: .*$/]
      output, status = fuzz(core.sub(CHECKED, UNCHECKED), seed: seed, volumes: volumes)
      abort("a link followed without its range checked passed:\n#{output}") if status.success? || !output.include?(VERDICT)
    end
    puts 'erx_fat_alloc reads only its FATs and FSInfo, and the unchecked copy does not pass'
  end

  # In a directory of its own, which also takes the crash dump of a failed round
  # and the image each verify reads.
  def fuzz(core_text, seed:, volumes:)
    Dir.mktmpdir('erx-fat-alloc-fuzz') do |work|
      core_path = File.join(work, File.basename(CORE))
      File.binwrite(core_path, core_text)
      include = Erx::Generated.path('erlang/apps/erx/include', root: ROOT)
      output, status = Open3.capture2e(ENV.fetch('ERX_ERLC'), '-I', include, '-o', work, core_path,
                                       *SOURCES.map { |source| File.join(ROOT, source) }, stdin_data: '')
      raise output unless status.success?

      Open3.capture2e({ 'ERX_FSIMG' => Erx::Fsimg.locate(root: ROOT) },
                      'gtimeout', '-k', '10', DEADLINE_SECONDS, ENV.fetch('ERX_ERL'), '-noshell', '-pa', work,
                      '-run', 'erx_fat_alloc_fuzz', 'run', seed.to_s, volumes, '-s', 'init', 'stop',
                      chdir: work, stdin_data: '')
    end
  end
end

if $PROGRAM_NAME == __FILE__
  seed = 1
  OptionParser.new { |flags| flags.on('--seed N', Integer) { |value| seed = value } }.parse!
  ErxFatAllocFuzz.run(seed: seed)
end
