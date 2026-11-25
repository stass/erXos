# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true
# erx-gate: fuzz seeded deadline=600

require 'open3'
require 'optparse'
require 'tmpdir'
require_relative '../lib/erx/generated'
require_relative '../lib/erx/fuzz_warm'

# The fuzz target of the partition table's reader, erx_media_table
# (test/erlang/erx_media_table_fuzz.erl, docs/design-drives.md "Fuzz targets"),
# compiled from source and run alone on stock's emulator (ERX_ERL and ERX_ERLC, the
# oracle's), so it needs no hosted build, over the media erx_media_table_cases writes
# as its seeds. It runs the reader as it is, then each seeded copy, which must fail
# with its verdict: one whose integrity check lets an entry end past the medium, so a
# mutated entry is served outside it, and one whose GPT metadata rule is dropped, so a
# volume is served over a sector of the table.
module ErxMediaTableFuzz
  ROOT = File.expand_path('../..', __dir__)
  CORE = 'erlang/apps/erx_media/src/erx_media_table.erl'
  SOURCES = %w[test/erlang/erx_media_table_cases.erl test/erlang/erx_media_table_fuzz.erl].freeze
  # An entry let past its usable area reaches either the medium's end or the backup
  # header there, so either verdict catches the first copy.
  Seeded = Data.define(:checked, :unchecked, :verdicts)
  SEEDED = [Seeded.new(checked: 'Last =< LastUsable orelse fail({past_the_end, [Number]})',
                       unchecked: 'is_integer(Last)', verdicts: %w[served_outside served_metadata]),
            Seeded.new(checked: 'andalso fail({gpt_metadata, Copy})', unchecked: 'andalso false',
                       verdicts: %w[served_metadata])].freeze
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
      abort("a copy without #{seeded.checked} passed:\n#{output}") if status.success? || seeded.verdicts.none? { |verdict| output.include?(verdict) }
    end
    puts 'erx_media_table serves only volumes inside the medium and apart from its table, and no seeded copy passes'
  end

  # In a directory of its own, which also takes the crash dump of a failed round.
  def fuzz(core_text, seed:)
    Dir.mktmpdir('erx-media-table-fuzz') do |work|
      core_path = File.join(work, File.basename(CORE))
      File.binwrite(core_path, core_text)
      include = Erx::Generated.path('erlang/apps/erx/include', root: ROOT)
      output, status = Open3.capture2e(ENV.fetch('ERX_ERLC'), '-I', include, '-o', work, core_path,
                                       *SOURCES.map { |source| File.join(ROOT, source) },
                                       Erx::FuzzWarm::SOURCE, stdin_data: '')
      raise output unless status.success?

      Open3.capture2e('gtimeout', '-k', '10', DEADLINE_SECONDS, ENV.fetch('ERX_ERL'), '-noshell', '-pa', work,
                      '-run', 'erx_media_table_fuzz', 'run', seed.to_s, '-s', 'init', 'stop',
                      chdir: work, stdin_data: '')
    end
  end
end

if $PROGRAM_NAME == __FILE__
  seed = 1
  OptionParser.new { |flags| flags.on('--seed N', Integer) { |value| seed = value } }.parse!
  ErxMediaTableFuzz.run(seed: seed)
end
