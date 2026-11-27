# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true
# erx-gate: fuzz seeded deadline=600

require 'open3'
require 'optparse'
require 'tmpdir'
require_relative '../lib/erx/generated'
require_relative '../lib/erx/fuzz_warm'

# The fuzz target of a raw file's request check, erx_media_raw:plan/3
# (test/erlang/erx_media_raw_fuzz.erl, docs/design-drives.md "Raw sectors"), compiled
# from source with the placement it calls, erx_media_table:place/3, and run alone on
# stock's emulator (ERX_ERL and ERX_ERLC, the oracle's), so it needs no hosted build.
# It runs the check as it is, then each seeded copy, which must fail with its verdict:
# one whose pieces ignore the window's max_sectors, so a piece larger than the window
# carries is sent, and one whose read is not cut at the file's end, so a read that runs
# past it is refused instead of answered short.
module ErxMediaRawFuzz
  ROOT = File.expand_path('../..', __dir__)
  CORE = 'erlang/apps/erx_media/src/erx_media_raw.erl'
  SOURCES = %w[erlang/apps/erx_media/src/erx_media_table.erl test/erlang/erx_media_raw_fuzz.erl].freeze
  Seeded = Data.define(:checked, :unchecked, :verdict)
  SEEDED = [Seeded.new(checked: 'N = min(Sectors, Piece),', unchecked: 'N = Sectors,', verdict: 'piece_too_large'),
            Seeded.new(checked: 'Sectors = max(0, min(Count div ?SECTOR, Length - First)),',
                       unchecked: 'Sectors = max(0, Count div ?SECTOR),', verdict: 'wrong_answer')].freeze
  DEADLINE_SECONDS = '300'

  module_function

  def run(seed:)
    Erx::Generated.ensure(root: ROOT)
    core = File.binread(File.join(ROOT, CORE))
    output, status = fuzz(core, seed: seed)
    abort(output) unless status.success? && output.match?(/^fuzz: \d+ rounds ok, \d+ accepted$/)
    SEEDED.each do |seeded|
      raise "#{CORE} does not hold #{seeded.checked} once" unless core.scan(seeded.checked).size == 1

      output, status = fuzz(core.sub(seeded.checked, seeded.unchecked), seed: seed)
      abort("a copy without #{seeded.checked} passed:\n#{output}") if status.success? || !output.include?(seeded.verdict)
    end
    puts 'erx_media_raw plans only pieces the window carries, inside their file, and no seeded copy passes'
  end

  # In a directory of its own, which also takes the crash dump of a failed round.
  def fuzz(core_text, seed:)
    Dir.mktmpdir('erx-media-raw-fuzz') do |work|
      core_path = File.join(work, File.basename(CORE))
      File.binwrite(core_path, core_text)
      include = [Erx::Generated.path('erlang/apps/erx/include', root: ROOT), File.join(ROOT, 'erlang/apps/erx/include')]
      Erx::FuzzWarm.compile(work: work,
                            sources: [core_path, *SOURCES.map { |source| File.join(ROOT, source) }], include: include)

      Open3.capture2e('gtimeout', '-k', '10', DEADLINE_SECONDS, ENV.fetch('ERX_ERL'), '-noshell', '-pa', work,
                      '-run', 'erx_media_raw_fuzz', 'run', seed.to_s, '-s', 'init', 'stop',
                      chdir: work, stdin_data: '')
    end
  end
end

if $PROGRAM_NAME == __FILE__
  seed = 1
  OptionParser.new { |flags| flags.on('--seed N', Integer) { |value| seed = value } }.parse!
  ErxMediaRawFuzz.run(seed: seed)
end
