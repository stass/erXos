# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'open3'
require 'optparse'
require 'tmpdir'
require_relative '../lib/erx/generated'

# The fuzz target of the virtio-input driver's pure core over what the device wrote,
# erx_virtio_input_core's event/1, absinfo/1, new/1 and its update fold, fold/2,
# compiled from source and run alone on stock's emulator (ERX_ERL and ERX_ERLC, the
# oracle's), so it needs no hosted build. It runs the module as it is, then each seeded
# copy, which must fail with its marker: one that takes an axis bound past its 32-bit
# register (the width check holds every read to what the device NIF can answer); one
# that takes an event record longer than the layout (the exact match holds each buffer to
# one event); one that sums wheel steps without their range check (the bound check holds
# every record the fold sends to erx_input:record()'s bounds); and one whose counts keep an entry per event dropped (the target
# holds the fold's state to the size new/1 gave it, so it keeps no event).
module ErxVirtioInputCoreFuzz
  ROOT = File.expand_path('../..', __dir__)
  # The generated header named here is in build/gen.
  Erx::Generated.ensure(root: ROOT)
  MODULE_SOURCE = File.join(ROOT, 'erlang/apps/erx_fb/src/erx_virtio_input_core.erl')
  FUZZ_SOURCE = File.join(ROOT, 'test/erlang/erx_virtio_input_core_fuzz.erl')
  INCLUDE = File.join(ROOT, 'build/gen/erlang/apps/erx/include')
  Seed = Data.define(:fault, :anchor, :replacement, :marker)
  SEEDS = [
    Seed.new(fault: "an axis bound taken past its register's width",
             anchor: 'absinfo({?ERX_VIRTIO_INPUT_ABSINFO_SIZE, Min, Max}) when ?WORD(Min), ?WORD(Max) ->',
             replacement: 'absinfo({?ERX_VIRTIO_INPUT_ABSINFO_SIZE, Min, Max}) when is_integer(Min), is_integer(Max) ->',
             marker: 'disagrees_with_reference'),
    Seed.new(fault: 'an event record longer than the layout taken',
             anchor: 'Value:32/little-signed>>) -> typed(Type, Code, Value);',
             replacement: 'Value:32/little-signed, _/binary>>) -> typed(Type, Code, Value);',
             marker: 'disagrees_with_reference'),
    Seed.new(fault: 'wheel steps summed without their range check',
             anchor: 'case is_wheel(Sum + Steps) of',
             replacement: 'case true of',
             marker: 'out_of_bounds'),
    Seed.new(fault: 'counts that keep an entry per event dropped',
             anchor: 'F#fold{counts = Counts#{Why := N + 1}}',
             replacement: 'F#fold{counts = Counts#{Why := N + 1, {Why, N} => N}}',
             marker: 'state_grew')
  ].freeze
  DEADLINE_SECONDS = '120'

  module_function

  def run(seed:)
    source = File.binread(MODULE_SOURCE)
    output, status = fuzz(source, seed: seed)
    abort(output) unless status.success? && output.match?(/^fuzz: \d+ rounds ok, \d+ accepted$/)
    SEEDS.each do |planted|
      raise "seed anchor for #{planted.fault} is not unique" unless source.scan(planted.anchor).size == 1

      output, status = fuzz(source.sub(planted.anchor) { planted.replacement }, seed: seed)
      abort("#{planted.fault} passed:\n#{output}") if status.success? || !output.include?(planted.marker)
    end
    puts 'erx_virtio_input_core agrees with its reference, and each seeded fault fails'
  end

  # In a directory of its own, which also takes the crash dump of a failed round. The
  # seeded copy may leave a variable unused, so nothing here compiles with -Werror.
  def fuzz(module_text, seed:)
    Dir.mktmpdir('erx-virtio-input-core-fuzz') do |work|
      module_path = File.join(work, 'erx_virtio_input_core.erl')
      File.binwrite(module_path, module_text)
      output, status = Open3.capture2e(ENV.fetch('ERX_ERLC'), '-I', INCLUDE, '-o', work, module_path, FUZZ_SOURCE,
                                       stdin_data: '')
      raise output unless status.success?

      Open3.capture2e('gtimeout', '-k', '10', DEADLINE_SECONDS, ENV.fetch('ERX_ERL'), '-noshell', '-pa', work,
                      '-run', 'erx_virtio_input_core_fuzz', 'run', seed.to_s, '-s', 'init', 'stop',
                      chdir: work, stdin_data: '')
    end
  end
end

if $PROGRAM_NAME == __FILE__
  options = { seed: 1 }
  OptionParser.new { |flags| flags.on('--seed N', Integer) { |value| options[:seed] = value } }.parse!
  ErxVirtioInputCoreFuzz.run(seed: options.fetch(:seed))
end
