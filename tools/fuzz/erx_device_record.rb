# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true
# erx-gate: fuzz seeded deadline=300

require 'open3'
require 'optparse'
require 'tmpdir'
require_relative '../lib/erx/generated'

# The fuzz target of erx_device_record:find/3, framebuffers/1, system_image/1 and drives/2, the parses
# of the device, framebuffer, system_image and drive records that the boot information carries to init's arguments, compiled from source and run alone on stock's
# emulator (ERX_ERL and ERX_ERLC, the oracle's), so it needs no hosted build. It runs the
# module as it is, then each seeded copy of MUTANTS, which must fail: a physical record that
# reads its line as 64 bits wide shows the reference holds each field to its width, a
# given record that keeps a memory key of 0 bytes shows it holds a device of no DMA to
# having no memory object, and a reader that takes a shared line for a direct one shows it
# holds each record to its line's mark, and one that reads a hardware address as 64 bits
# wide shows it holds MAC to 48, one that reads a given record's INDEX as 64 bits wide that it
# holds INDEX to 32, and one that reads a null line handle as a line that it holds a device
# whose node raises no line to having none, and one that takes that null line marked shared that
# it refuses the mark. For framebuffers, a reader that takes a stride a byte short
# of a row, rows past the record's bytes, or r8g8b8 as 16 bits a pixel shows the reference
# holds a record to the geometry the tree's reader passed. For system_image, a reader that
# takes a root hash of any length, a salt of no bytes or of 33, any sixth word as the
# record_volume window's name, or the first of two records shows the reference holds the
# record to its one shape. For drives, a reader that takes any role word, makes an unknown one an
# atom, keeps a number named twice, takes mf_none as a number, or takes five usb records or two
# block shows the reference holds a domain to its whole set of drives or none.
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
    'reading a given index as 64 bits wide' => ["number(Index, 32)},\n          mark(Mark)", "number(Index, 64)},\n          mark(Mark)"],
    'taking a null line marked shared' => ["{{ok, [_, _, _, ?ERX_CAP_NULL, _, _]}, {{ok, _}, {ok, _}}, {ok, shared},", "{{ok, [_, _, _, -1, _, _]}, {{ok, _}, {ok, _}}, {ok, shared},"],
    'reading a null line handle as a line' => ["given_lines(_Sharing, ?ERX_CAP_NULL) -> [];\n", ''],
    'taking a stride short of a row' => ['R * 8 >= X * Bits', 'R * 8 + 8 >= X * Bits'],
    'taking rows past the bytes' => ['R * Y =< S', 'R * (Y - 1) =< S'],
    'reading r8g8b8 as 16 bits a pixel' => ['{ok, r8g8b8, 24}', '{ok, r8g8b8, 16}'],
    'taking a path a byte over the bound' => ['length(Word) =< ?ERX_DEVICE_PATH_MAX', 'length(Word) =< ?ERX_DEVICE_PATH_MAX + 1'],
    'taking a space in a path' => ['lists:member(C, ",._+-@/")', 'lists:member(C, ",._+-@/ ")'],
    'taking a root hash of any length' => ['hex(Root, ?ERX_VERITY_HASH_SIZE, ?ERX_VERITY_HASH_SIZE)', 'hex(Root, 1, 2 * ?ERX_VERITY_HASH_SIZE)'],
    'taking a salt of no bytes' => ['hex(Salt, 1, ?ERX_VERITY_SALT_SIZE)', 'hex(Salt, 0, ?ERX_VERITY_SALT_SIZE)'],
    'taking a salt of 33 bytes' => ['hex(Salt, 1, ?ERX_VERITY_SALT_SIZE)', 'hex(Salt, 1, ?ERX_VERITY_SALT_SIZE + 1)'],
    'reading any sixth word as the record_volume window' => ['Windows =:= ["record_volume"] ->', 'length(Windows) =:= 1 ->'],
    'taking the first of two system_image records' => ["case [Words || [\"system_image\" | Words] <- Arguments] of", "case lists:sublist([Words || [\"system_image\" | Words] <- Arguments], 1) of"],
    'taking a placed BAR of 8 bytes' => ['S >= 4 andalso S =< ?ERX_PCIE_BAR_SIZE_LOG2_MAX', 'S >= 3 andalso S =< ?ERX_PCIE_BAR_SIZE_LOG2_MAX'],
    'reading a function number as 8 bits wide' => ['at_most(Function, ?ERX_PCIE_FUNCTION_MAX)', 'number(Function, 8)'],
    'taking a function record with a null line marked shared' => ["function_lines(shared, ?ERX_CAP_NULL) -> bad(\"a function record marks no line shared\");\n", ''],
    'taking an MSI-X table in another BAR' => ['#{bar := Bar, offset := Offset', '#{bar := _, offset := Offset'],
    'taking an MSI-X table of no entries' => ['when Entries >= 1, Entries', 'when Entries >= 0, Entries'],
    'taking an MSI-X table that ends past its BAR' => ['Offset + Entries * ?ERX_PCIE_MSIX_ENTRY_SIZE =< Size', 'Offset < Size'],
    'taking any drive role word' => ['drive_records([[RoleWord, Word] | Rest], Drives) when RoleWord =:= "usb"; RoleWord =:= "block" ->',
                                     'drive_records([[RoleWord, Word] | Rest], Drives) ->'],
    'making an unknown drive role word an atom' => ["drive_records([[_, _] | _], _Drives) ->\n", "drive_records([[R, _] | _], _Drives) ->\n    _ = list_to_atom(R),\n"],
    'keeping a drive number named twice' => ['length(lists:usort(Numbers)) =:= length(Numbers)', 'true'],
    'taking mf_none as a drive number' => ['at_most(Word, ?ERX_MF_NONE - 1)', 'at_most(Word, ?ERX_MF_NONE)'],
    'taking five usb drives' => ['Usb > ?ERX_USB_DRIVES_MAX ->', 'Usb > ?ERX_USB_DRIVES_MAX + 1 ->'],
    'taking two block drives' => ['Block > 1 ->', 'Block > 2 ->']
  }.freeze
  DEADLINE_SECONDS = '120'

  module_function

  def run(seed:)
    source = File.binread(MODULE_SOURCE)
    MUTANTS.each_value { |from, _to| raise "#{from.inspect} is not in #{MODULE_SOURCE}" unless source.include?(from) }

    output, status = fuzz(source, seed: seed)
    abort(output) unless status.success? && output.match?(/^fuzz: \d+ rounds ok, \d+ accepted, \d+ functions accepted, \d+ framebuffers accepted, \d+ system images accepted, \d+ drive sets accepted$/)
    MUTANTS.each do |name, (from, to)|
      output, status = fuzz(source.sub(from, to), seed: seed)
      abort("#{name} passed:\n#{output}") if status.success? || !output.include?('disagrees_with_reference')
    end
    puts "erx_device_record:find/3, for device and function records, framebuffers/1, system_image/1 and drives/2 agree with their references, and no seeded copy does (#{MUTANTS.keys.join('; ')})"
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
