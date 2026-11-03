# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'minitest/autorun'
require 'json'
require_relative '../../tools/lib/erx/stack_graph_input'

# The readers of the stack graph's tool outputs refuse every line and field
# they do not recognize, naming the object, rather than skipping it.
class StackGraphInputTest < Minitest::Test
  Input = Erx::StackGraphInput
  OBJECT = 'core.o'

  def test_frame_records_are_read
    frames = Input.stack_usage("src/a:b.c:7:plain\t32\tstatic\nsrc/a.c:9:12:leaf\t0\tstatic\n", object: OBJECT)
    assert_equal Input::Frame.new(bytes: 32, location: 'src/a:b.c:7'), frames.fetch('plain')
    assert_equal 'src/a.c:9:12', frames.fetch('leaf').location
  end

  def test_malformed_frame_records_are_refused
    {
      "a.c:7:plain\t32\n" => 'line 1 is not a frame record',
      "a.c:7:plain\t32\tstatic\na.c:8:plain\t16\tstatic\n" => 'plain: two stack-usage records',
      "a.c:7:sized\t64\tdynamic,bounded\n" => 'sized: dynamic frame (dynamic,bounded)',
      "a.c:7:odd\t64\tstrange\n" => 'odd: unknown frame qualifier strange',
      "a.c:7:huge\t9999999999\tstatic\n" => 'huge: frame of 9999999999 bytes exceeds',
      "a.c:7:x.cold\t8\tstatic\n" => 'line 1 is not a frame record',
      "a.c:7:esc\e\t8\tstatic\n" => 'hold control characters',
      "a.c:7:#{'n' * 5000}\t8\tstatic\n" => 'line 1 exceeds 4096 bytes'
    }.each do |text, message|
      assert_refused(message) { Input.stack_usage(text, object: OBJECT) }
    end
  end

  def test_disassembly_is_read_by_section
    text = "\ncore.o:\tfile format elf64-littleaarch64\n\nDisassembly of section .text.f:\n\n" \
           "0000000000000000 <f>:\n       0: d10043ff     \tsub\tsp, sp, #0x10\n" \
           "       4: d65f03c0     \tret\n"
    code = Input.disassembly(text, object: OBJECT).fetch('.text.f')
    assert_equal [[0, 0xd100_43ff, 'sub'], [4, 0xd65f_03c0, 'ret']], code.map { [_1.offset, _1.word, _1.mnemonic] }
  end

  def test_malformed_disassembly_is_refused
    heading = "Disassembly of section .text:\n"
    {
      "       0: d10043ff     \tsub\tsp, sp, #0x10\n" => 'instruction outside a section',
      "#{heading}warning: something odd\n" => 'line 2 is not an instruction, label or section heading',
      "#{heading}\t\t...\n" => 'line 2 is not an instruction',
      "#{heading}#{heading}" => 'section .text is disassembled twice',
      "core.o:\tfile format elf64-bigaarch64\n" => 'line 1 is not an instruction'
    }.each do |text, message|
      assert_refused(message) { Input.disassembly(text, object: OBJECT) }
    end
  end

  def test_malformed_listings_are_refused
    summary = { FileSummary: { Format: 'elf64-littleaarch64' },
                ElfHeader: { Type: 'Relocatable (0x1)', Machine: { Name: 'EM_AARCH64' } },
                Sections: [], Symbols: [], Relocations: [] }
    assert_empty Input.listing(JSON.generate([summary]), object: OBJECT).sections
    {
      '[{' => 'invalid readobj listing: malformed JSON',
      ('[' * 100) + (']' * 100) => 'malformed JSON',
      JSON.generate([summary.merge(FileSummary: { Format: 'elf64-bigaarch64' })]) => 'not one little-endian',
      JSON.generate([summary.merge(ElfHeader: { Type: 'Executable (0x2)', Machine: { Name: 'EM_AARCH64' } })]) =>
        'not one little-endian',
      JSON.generate([summary, summary]) => 'not one little-endian',
      JSON.generate([summary.merge(Sections: [{ Section: { Index: 1 } }])]) => 'section entry has an unknown shape',
      JSON.generate([summary.merge(Relocations: [{ SectionIndex: 9, Relocs: [] }])]) =>
        'relocation group names no section 9'
    }.each do |text, message|
      assert_refused(message) { Input.listing(text, object: OBJECT) }
    end
  end

  private

  def assert_refused(message)
    error = assert_raises(Erx::StackGraphError) { yield }
    assert_includes error.message, "stack graph: #{OBJECT}: "
    assert_includes error.message, message
  end
end
