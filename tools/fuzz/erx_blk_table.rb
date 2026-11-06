# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'open3'
require 'optparse'
require 'tmpdir'

# The fuzz target of the block driver's parse of the boot medium's partition table,
# erx_blk_table:admit/4, and of a window's check, place/3, compiled from source and run
# alone on stock's emulator (ERX_ERL and ERX_ERLC, the oracle's), so it needs no hosted
# build. It runs the module as it is, then a copy that admits a data partition running
# past the medium's end, which must fail: that shows the reference holds the data
# partition to the medium.
module ErxBlkTableFuzz
  ROOT = File.expand_path('../..', __dir__)
  MODULE_SOURCE = File.join(ROOT, 'erlang/apps/erx_blk/src/erx_blk_table.erl')
  SOURCES = [File.join(ROOT, 'test/erlang/erx_blk_table_fuzz.erl')].freeze
  INCLUDE = File.join(ROOT, 'erlang/apps/erx/include')
  WITHIN = '?ERX_MEDIUM_DATA_START + Sectors =< Capacity'
  ANYWHERE = 'true'
  DEADLINE_SECONDS = '120'

  module_function

  def run(seed:)
    source = File.binread(MODULE_SOURCE)
    raise "no data partition bound in #{MODULE_SOURCE}" unless source.include?(WITHIN)

    output, status = fuzz(source, seed: seed)
    abort(output) unless status.success? && output.match?(/^fuzz: \d+ rounds ok, \d+ accepted$/)
    output, status = fuzz(source.sub(WITHIN, ANYWHERE), seed: seed)
    abort("admitting a data partition past the medium passed:\n#{output}") if status.success? ||
                                                                     !output.include?('disagrees_with_reference')
    puts 'erx_blk_table:admit/4 agrees with its reference, and admitting a data partition past the medium does not'
  end

  # In a directory of its own, which also takes the crash dump of a failed round.
  def fuzz(module_text, seed:)
    Dir.mktmpdir('erx-blk-table-fuzz') do |work|
      module_path = File.join(work, 'erx_blk_table.erl')
      File.binwrite(module_path, module_text)
      output, status = Open3.capture2e(ENV.fetch('ERX_ERLC'), '-I', INCLUDE, '-o', work, module_path, *SOURCES, stdin_data: '')
      raise output unless status.success?

      Open3.capture2e('gtimeout', '-k', '10', DEADLINE_SECONDS, ENV.fetch('ERX_ERL'), '-noshell', '-pa', work,
                      '-run', 'erx_blk_table_fuzz', 'run', seed.to_s, '-s', 'init', 'stop',
                      chdir: work, stdin_data: '')
    end
  end
end

if $PROGRAM_NAME == __FILE__
  options = { seed: 1 }
  OptionParser.new { |flags| flags.on('--seed N', Integer) { |value| options[:seed] = value } }.parse!
  ErxBlkTableFuzz.run(seed: options.fetch(:seed))
end
