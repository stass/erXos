# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'open3'
require 'optparse'
require 'tmpdir'
require_relative '../lib/erx/generated'

# The fuzz target of erx_vt:feed/2, the terminal emulator's parser of a program's output
# (docs/design-display.md, "Verification and testing"). It is compiled from source with the
# generated width table and run alone on stock's emulator (ERX_ERL and ERX_ERLC, the
# oracle's), as the module is and then as copies that each break one guarantee, each of
# which must fail with the property that guards it: that shows the streams reach every
# bound and that the checks catch a break.
module ErxVtFuzz
  ROOT = File.expand_path('../..', __dir__)
  MODULE_SOURCE = File.join(ROOT, 'erlang/apps/erx_win/src/erx_vt.erl')
  TARGET_SOURCE = File.join(ROOT, 'test/erlang/erx_vt_fuzz.erl')
  # The width table and erx_present, by which erx_vt reads erx: links, with erx_schema.
  GENERATED = %w[erlang/apps/erx_win/src/erx_vt_width.erl erlang/apps/erx/src/generated/erx_present.erl
                 erlang/apps/erx/src/generated/erx_schema.erl].freeze
  # A broken guarantee: the text that keeps it, what replaces it, and the property that
  # must then fail, as the target names it.
  Seed = Data.define(:text, :broken, :property)
  SEEDED = {
    'the 16-parameter bound' => Seed.new(text: 'when Count >= ?MAX_PARAMS -> P#parser{current = none}',
                                         broken: 'when Count >= 4 * ?MAX_PARAMS -> P#parser{current = none}',
                                         property: 'parser_over_bound'),
    'the 4 KiB OSC bound' => Seed.new(text: 'Longer when byte_size(Longer) > ?MAX_OSC -> overflow',
                                      broken: 'Longer when byte_size(Longer) > 2 * ?MAX_OSC -> overflow',
                                      property: 'parser_over_bound'),
    'the repair of a split width-2 cell' => Seed.new(text: 'list_to_tuple(repair(Edited, Blank))',
                                                     broken: 'list_to_tuple(Edited)',
                                                     property: 'wide_cell_unpaired'),
    'UTF-8 carried between calls' => Seed.new(text: 'more -> VT#vt{utf8 = Bytes}', broken: 'more -> VT',
                                              property: 'split_differs'),
    'the 256-link bound' => Seed.new(text: 'Kept = maps:remove(Id - ?MAX_LINKS, Links),', broken: 'Kept = Links,',
                                     property: 'links_over_bound')
  }.freeze
  DEADLINE_SECONDS = '600'

  module_function

  def run(seed:)
    Erx::Generated.ensure(root: ROOT)
    source = File.binread(MODULE_SOURCE)
    output, status = fuzz(source, seed: seed)
    abort(output) unless status.success? && output.match?(/^fuzz: \d+ rounds ok$/)
    SEEDED.each do |guarantee, planted|
      raise "no #{guarantee} (#{planted.text}) in #{MODULE_SOURCE}" unless source.include?(planted.text)

      output, status = fuzz(source.sub(planted.text, planted.broken), seed: seed)
      unless !status.success? && output.include?("fuzz_failure,#{planted.property}")
        abort("erx_vt without #{guarantee} did not fail #{planted.property}:\n#{output[0, 4000]}")
      end
    end
    puts "erx_vt:feed/2 keeps its invariants, and copies without #{SEEDED.keys.join(', ')} do not"
  end

  # In a directory of its own, which also takes the crash dump of a failed round.
  def fuzz(module_text, seed:)
    Dir.mktmpdir('erx-vt-fuzz') do |work|
      module_path = File.join(work, 'erx_vt.erl')
      File.binwrite(module_path, module_text)
      generated = GENERATED.map { |path| Erx::Generated.path(path, root: ROOT) }
      output, status = Open3.capture2e('gtimeout', '-k', '10', DEADLINE_SECONDS, ENV.fetch('ERX_ERLC'), '-o', work,
                                       *generated, module_path, TARGET_SOURCE, stdin_data: '')
      raise output unless status.success?

      Open3.capture2e('gtimeout', '-k', '10', DEADLINE_SECONDS, ENV.fetch('ERX_ERL'), '-noshell', '-pa', work,
                      '-run', 'erx_vt_fuzz', 'run', seed.to_s, '-s', 'init', 'stop', chdir: work, stdin_data: '')
    end
  end
end

if $PROGRAM_NAME == __FILE__
  seed = 1
  OptionParser.new { |flags| flags.on('--seed N', Integer) { |value| seed = value } }.parse!
  ErxVtFuzz.run(seed: seed)
end
