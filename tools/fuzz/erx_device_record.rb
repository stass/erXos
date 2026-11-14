# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'open3'
require 'optparse'
require 'tmpdir'
require_relative '../lib/erx/generated'

# The fuzz target of erx_device_record:find/3 and framebuffers/1, the parses of the device and
# framebuffer records that the boot information carries to init's arguments, compiled from source and run alone on stock's
# emulator (ERX_ERL and ERX_ERLC, the oracle's), so it needs no hosted build. It runs the
# module as it is, then each seeded copy of MUTANTS, which must fail: a physical record that
# reads its line as 64 bits wide shows the reference holds each field to its width, a
# given record that keeps a memory key of 0 bytes shows it holds a device of no DMA to
# having no memory object, and a reader that takes a shared line for a direct one shows it
# holds each record to its line's mark, and one that reads a hardware address as 64 bits
# wide shows it holds MAC to 48. For framebuffers, a reader that takes a stride a byte short
# of a row, rows past the record's bytes, or r8g8b8 as 16 bits a pixel shows the reference
# holds a record to the geometry the tree's reader passed.
module ErxDeviceRecordFuzz
  ROOT = File.expand_path('../..', __dir__)
  MODULE_SOURCE = File.join(ROOT, 'erlang/apps/erx/src/erx_device_record.erl')
  TARGET_SOURCE = File.join(ROOT, 'test/erlang/erx_device_record_fuzz.erl')
  # What each seeded copy says, the text it replaces and the text it plants.
  MUTANTS = {
    'reading a line as 64 bits wide' => ['number(Line, 32)', 'number(Line, 64)'],
    'keeping a memory key of 0 bytes' => ["with_memory(Spec, _Memory, 0) -> Spec;\n", ''],
    'reading a shared line as direct' => ['marked(shared, Line) -> {shared, Line}.', 'marked(shared, Line) -> Line.'],
    'reading a hardware address as 64 bits wide' => ['number(Mac, 48)', 'number(Mac, 64)'],
    'taking a stride short of a row' => ['R * 8 >= X * Bits', 'R * 8 + 8 >= X * Bits'],
    'taking rows past the bytes' => ['R * Y =< S', 'R * (Y - 1) =< S'],
    'reading r8g8b8 as 16 bits a pixel' => ['{ok, r8g8b8, 24}', '{ok, r8g8b8, 16}'],
    'taking a path a byte over the bound' => ['length(Word) =< ?ERX_DEVICE_PATH_MAX', 'length(Word) =< ?ERX_DEVICE_PATH_MAX + 1'],
    'taking a space in a path' => ['lists:member(C, ",._+-@/")', 'lists:member(C, ",._+-@/ ")']
  }.freeze
  DEADLINE_SECONDS = '120'

  module_function

  def run(seed:)
    source = File.binread(MODULE_SOURCE)
    MUTANTS.each_value { |from, _to| raise "#{from.inspect} is not in #{MODULE_SOURCE}" unless source.include?(from) }

    output, status = fuzz(source, seed: seed)
    abort(output) unless status.success? && output.match?(/^fuzz: \d+ rounds ok, \d+ accepted, \d+ framebuffers accepted$/)
    MUTANTS.each do |name, (from, to)|
      output, status = fuzz(source.sub(from, to), seed: seed)
      abort("#{name} passed:\n#{output}") if status.success? || !output.include?('disagrees_with_reference')
    end
    puts "erx_device_record:find/3 and framebuffers/1 agree with their references, and no seeded copy does (#{MUTANTS.keys.join('; ')})"
  end

  # In a directory of its own, which also takes the crash dump of a failed round.
  def fuzz(module_text, seed:)
    Dir.mktmpdir('erx-device-record-fuzz') do |work|
      module_path = File.join(work, 'erx_device_record.erl')
      File.binwrite(module_path, module_text)
      # The generated erx_abi.hrl both modules include, which build/gen holds once ensured.
      Erx::Generated.ensure(root: ROOT)
      output, status = Open3.capture2e(ENV.fetch('ERX_ERLC'), '-I', Erx::Generated.path('erlang/apps/erx/include', root: ROOT),
                                       '-o', work, module_path, TARGET_SOURCE, stdin_data: '')
      raise output unless status.success?

      Open3.capture2e('gtimeout', '-k', '10', DEADLINE_SECONDS, ENV.fetch('ERX_ERL'), '-noshell', '-pa', work,
                      '-run', 'erx_device_record_fuzz', 'run', seed.to_s, '-s', 'init', 'stop',
                      chdir: work, stdin_data: '')
    end
  end
end

if $PROGRAM_NAME == __FILE__
  seed = 1
  OptionParser.new { |flags| flags.on('--seed N', Integer) { |value| seed = value } }.parse!
  ErxDeviceRecordFuzz.run(seed: seed)
end
