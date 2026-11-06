# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'open3'
require 'optparse'
require 'tmpdir'

# The fuzz target of erx_ramfs_core, the pure tree behind each domain's /tmp: random
# request sequences through step/4 with check/1 after every step
# (test/erlang/erx_ramfs_core_fuzz.erl), compiled from source and run on stock's emulator
# (ERX_ERL and ERX_ERLC, the oracle's). It runs the module as it is, then a copy whose
# truncation keeps the charge of the chunks it frees, which check/1's recomputed charge
# must catch, and a copy whose forget keeps the hold it lets go of, which check/1's
# recount of the holders must catch: that shows the sequences reach truncation and
# forgets, and that check/1 reads the charge and the holds.
module ErxRamfsCoreFuzz
  ROOT = File.expand_path('../..', __dir__)
  MODULE_SOURCE = File.join(ROOT, 'erlang/apps/erx_files/src/erx_ramfs_core.erl')
  TARGET_SOURCE = File.join(ROOT, 'test/erlang/erx_ramfs_core_fuzz.erl')
  TRUNCATE_CHARGE = 'Charge = -(map_size(Chunks) - map_size(Kept)) * ?CHUNK_BYTES,'
  KEPT_CHARGE = 'Charge = 0 * map_size(Kept) * map_size(Chunks),'
  FORGET_HOLD = 'N1 = N#node{holds = Holds - 1},'
  KEPT_HOLD = 'N1 = N#node{holds = Holds + 0 * Holds},'
  DEADLINE_SECONDS = '240'

  module_function

  def run(seed:)
    source = File.binread(MODULE_SOURCE)
    raise "no truncation charge in #{MODULE_SOURCE}" unless source.include?(TRUNCATE_CHARGE)
    raise "no forgotten hold in #{MODULE_SOURCE}" unless source.include?(FORGET_HOLD)

    output, status = fuzz(source, seed: seed)
    abort(output) unless status.success? && output.match?(/^fuzz: \d+ sequences ok$/)
    output, status = fuzz(source.sub(TRUNCATE_CHARGE, KEPT_CHARGE), seed: seed)
    abort("a truncation keeping its charge passed:\n#{output}") if status.success? || !output.include?('check_failed')
    output, status = fuzz(source.sub(FORGET_HOLD, KEPT_HOLD), seed: seed)
    abort("a forget keeping its hold passed:\n#{output}") if status.success? || !output.include?('check_failed')
    puts 'erx_ramfs_core keeps its invariants over every sequence, and neither a truncation keeping its ' \
         'charge nor a forget keeping its hold does'
  end

  # In a directory of its own, which also takes the crash dump of a failed sequence.
  def fuzz(module_text, seed:)
    Dir.mktmpdir('erx-ramfs-core-fuzz') do |work|
      module_path = File.join(work, 'erx_ramfs_core.erl')
      File.binwrite(module_path, module_text)
      output, status = Open3.capture2e(ENV.fetch('ERX_ERLC'), '-o', work, module_path, TARGET_SOURCE, stdin_data: '')
      raise output unless status.success?

      Open3.capture2e('gtimeout', '-k', '10', DEADLINE_SECONDS, ENV.fetch('ERX_ERL'), '-noshell', '-pa', work,
                      '-run', 'erx_ramfs_core_fuzz', 'run', seed.to_s, '-s', 'init', 'stop', chdir: work, stdin_data: '')
    end
  end
end

if $PROGRAM_NAME == __FILE__
  seed = 1
  OptionParser.new { |flags| flags.on('--seed N', Integer) { |value| seed = value } }.parse!
  ErxRamfsCoreFuzz.run(seed: seed)
end
