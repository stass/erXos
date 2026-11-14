# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'minitest/autorun'
require 'fileutils'
require 'open3'
require 'rbconfig'
require 'tmpdir'

# The library under test, or a seeded copy of it when a seed case runs this file again
# in a child process (see run_case_against_seed).
LIBRARY = ENV.fetch('ERX_KEYMAP_TEST_LIBRARY', File.expand_path('../../tools/lib', __dir__))
require File.join(LIBRARY, 'erx/keymap')

# tools/lib/erx/keymap.rb, the keyboard layouts' generator (docs/design-display.md,
# "Input events"): each refusal its section names, a layout that names a code outside
# the enum evdev, a code twice, a special rune outside the enum input_rune, a row of the
# wrong width, a surrogate, a code point past U+10FFFF or a byte above 0x7f, or whose
# keymap line differs from its file's name; then the generated erx_keymap, compiled and
# run on stock's emulator (ERX_ERL and ERX_ERLC), against a table of every key of the US
# layout written here from 9front's map, independently of abi/keymaps/us.txt. Two seeded
# generators, one taking a key state for a key and one keeping the first of two rows for
# one code, must each fail its case.
class KeymapTest < Minitest::Test
  ROOT = File.expand_path('../..', __dir__)
  DEADLINE_SECONDS = '120'
  PATH = 'abi/keymaps/us.txt'
  SCHEMA = Erx::ABI::Model.validate(Erx::ABI::Sources.read(root: ROOT))
  VOCABULARY = Erx::Keymap.vocabulary(SCHEMA)
  A_ROW = 'key KEY_A a A U+0001 a A caps'

  def parse(*rows, keymap: 'keymap us', path: PATH)
    Erx::Keymap.parse(path: path, text: [keymap, *rows].compact.join("\n") + "\n", vocabulary: VOCABULARY)
  end

  def assert_refused(pattern, *rows, **options)
    error = assert_raises(Erx::Keymap::LayoutError) { parse(*rows, **options) }
    assert_match pattern, error.message
  end

  def test_a_layout_of_closed_set_names_parses
    layout = parse(A_ROW, 'key KEY_UP Kup Kup Kup Kup Kup', 'modifier KEY_LEFTSHIFT Kshift shift',
                   'lock KEY_CAPSLOCK Kcaps caps', 'button BTN_LEFT 1')
    assert_equal 'us', layout.name
    assert_equal [30, 42, 58, 103, 0x110], layout.rows.map { |row| row.code.value }
  end

  # The key states and KEY_MAX share the KEY_ prefix and are entries of evdev.txt, and
  # KEY_RESERVED and BTN_MISC are evdev's names too, but none of them is a member of the
  # enum evdev.
  def test_a_key_state_is_no_key
    %w[KEY_EVENT_DOWN KEY_EVENT_UP KEY_RESERVED KEY_MAX BTN_MISC EV_KEY KEY_COMPOSE key_a].each do |name|
      assert_refused(/#{name} is not a key or button code of the enum evdev/,
                     "key #{name} Kesc Kesc Kesc Kesc Kesc")
    end
  end

  def test_a_code_named_twice_is_refused
    assert_refused(/us\.txt:3: KEY_A has a row already/, A_ROW, A_ROW)
    assert_refused(/KEY_LEFTSHIFT has a row already/, 'modifier KEY_LEFTSHIFT Kshift shift',
                   'key KEY_LEFTSHIFT a A a a A')
  end

  def test_the_keymap_line_names_the_file
    assert_refused(/keymap de in a file named us/, A_ROW, keymap: 'keymap de')
    assert_refused(/no keymap line/, '# a comment alone', keymap: nil)
    assert_refused(/a row before the keymap line/, A_ROW, 'keymap us', keymap: '# us')
    assert_refused(/a second keymap line/, 'keymap us', keymap: 'keymap us')
    assert_refused(/keymap takes one name/, keymap: 'keymap us extra')
    assert_refused(/"US" is not a layout name/, A_ROW, keymap: 'keymap US', path: 'abi/keymaps/US.txt')
  end

  def test_an_unknown_special_rune_is_refused
    %w[Kfoo Kview Kmouse KUP kup ab].each do |name|
      assert_refused(/#{name} is not a special rune of the enum input_rune/, "key KEY_UP #{name} Kup Kup Kup Kup")
    end
    assert_refused(/Kfoo is not a special rune/, 'modifier KEY_LEFTSHIFT Kfoo shift')
  end

  def test_a_row_of_the_wrong_width_is_refused
    assert_refused(/a key row of 6 tokens/, 'key KEY_A a A U+0001 a')
    assert_refused(/a key row of 9 tokens/, "#{A_ROW} caps")
    assert_refused(/a key row of 2 tokens/, 'key KEY_A')
    assert_refused(/a modifier row of 3 tokens/, 'modifier KEY_LEFTSHIFT Kshift')
    assert_refused(/a lock row of 5 tokens/, 'lock KEY_CAPSLOCK Kcaps caps caps')
    assert_refused(/a button row of 4 tokens/, 'button BTN_LEFT 1 2')
    assert_refused(/a key row ends in caps/, 'key KEY_A a A U+0001 a A shift')
  end

  def test_a_surrogate_or_a_code_point_past_unicode_is_refused
    assert_refused(/U\+D800 is a surrogate/, 'key KEY_A U+D800 A U+0001 a A')
    assert_refused(/U\+DFFF is a surrogate/, 'key KEY_A a U+DFFF U+0001 a A')
    assert_refused(/U\+110000 is past U\+10FFFF/, 'key KEY_A a A U+110000 a A')
    assert_refused(/U\+123 is not a special rune/, 'key KEY_A a A U+123 a A')
    assert_equal 0x10ffff, parse('key KEY_A U+10FFFF A U+0001 a A').rows.first.layers.fetch('none').point
  end

  def test_a_byte_outside_printable_ascii_is_refused
    assert_refused(/us\.txt:2: a byte above 0x7f, 0xc3/, "key KEY_A \u00e9 A U+0001 a A".b)
    assert_refused(/a byte above 0x7f/, "# caf\u00e9".b)
    assert_refused(/a control byte, 0x09/, "key KEY_A\ta A U+0001 a A")
    assert_refused(/a control byte, 0x0d/, "#{A_ROW}\r")
  end

  def test_other_closed_fields_are_refused
    assert_refused(/mod4 is not a modifier/, 'modifier KEY_LEFTMETA Kmod4 mod4')
    assert_refused(/num is not a lock/, 'lock KEY_NUMLOCK Knum num')
    assert_refused(/3 is not a Plan 9 button bit/, 'button BTN_LEFT 3')
    assert_refused(/repeat is not a row of a layout/, 'repeat 500 126')
  end

  # The generated module against a table of every key of the US layout.
  def test_the_generated_module_maps_the_us_layout
    lines = module_output(root: ROOT, eval: DUMP)
    rows = lines.grep_v(/\Alayouts /)
    layouts = lines.grep(/\Alayouts /).first&.delete_prefix('layouts ')
    assert_equal '[us]', layouts
    expected = UsLayout.lines
    assert_equal expected.size, rows.size
    assert_empty expected - rows, "rows the module lacks or maps otherwise:\n#{(expected - rows).join("\n")}"
  end

  # A layout's name becomes a quoted atom, so a reserved word names a layout like any other.
  def test_a_layout_named_by_a_reserved_word_compiles
    with_abi_copy do |root|
      File.write(File.join(root, 'abi/keymaps/end.txt'), "keymap end\n#{A_ROW}\n")
      eval = "io:format(\"~w ~w~n\", [erx_keymap:layouts(), element(1, erx_keymap:row('end', 30))]), halt(0)."
      assert_equal ["['end',us] key"], module_output(root: root, eval: eval)
    end
  end

  def test_a_tree_without_a_layout_is_refused
    with_abi_copy do |root|
      FileUtils.rm_r(File.join(root, 'abi/keymaps'))
      error = assert_raises(Erx::Keymap::LayoutError) { Erx::Keymap.generation(root: root) }
      assert_match %r{no keyboard layout matches abi/keymaps/\*\.txt}, error.message
    end
  end

  Seed = Data.define(:fault, :anchor, :replacement, :catching_case)
  SEEDS = [
    Seed.new(fault: 'a key state accepted as a key',
             anchor: 'codes = enum(schema, CODE_ENUM).members',
             replacement: "codes = schema.constants.select { |name, _| name.start_with?('evdev_key_', 'evdev_btn_') }\n" \
                          "                    .to_h { |name, constant| [name.delete_prefix('evdev_'), constant.value] }",
             catching_case: 'test_a_key_state_is_no_key'),
    Seed.new(fault: 'the first of two rows for one code kept',
             anchor: 'raise LayoutError, "#{where}: #{tokens[1]} has a row already"',
             replacement: 'next',
             catching_case: 'test_a_code_named_twice_is_refused')
  ].freeze

  def test_each_seeded_generator_fails_its_case
    return skip('a seed case runs only against the tree') if ENV.key?('ERX_KEYMAP_TEST_LIBRARY')

    SEEDS.each do |seed|
      output, status = run_case_against_seed(seed)
      refute status.success?, "#{seed.fault}: #{seed.catching_case} passed:\n#{output}"
      assert_match(/Failure:\nKeymapTest##{seed.catching_case} .*\n.*LayoutError expected but nothing was raised/,
                   output, seed.fault)
      assert_match(/1 runs/, output, "#{seed.fault}: the child ran other than its one case")
    end
  end

  private

  # A copy of tools/lib with the seed applied, and this file's catching case run in a
  # child against it.
  def run_case_against_seed(seed)
    Dir.mktmpdir('erx-keymap-seed') do |work|
      FileUtils.cp_r(File.join(ROOT, 'tools/lib'), work)
      generator = File.join(work, 'lib/erx/keymap.rb')
      source = File.read(generator)
      assert_equal 1, source.scan(seed.anchor).size, "seed anchor for #{seed.fault} is not unique"
      File.write(generator, source.sub(seed.anchor) { seed.replacement })
      Open3.capture2e({ 'ERX_KEYMAP_TEST_LIBRARY' => File.join(work, 'lib') },
                      'gtimeout', '-k', '10', DEADLINE_SECONDS, RbConfig.ruby, __FILE__,
                      '-n', seed.catching_case, stdin_data: '')
    end
  end

  # A root holding a copy of the tree's abi/, the generator's only input.
  def with_abi_copy
    Dir.mktmpdir('erx-keymap-root') do |root|
      FileUtils.cp_r(File.join(ROOT, 'abi'), root)
      yield root
    end
  end

  # The module the generator plans for root, compiled against root's erx_abi.hrl, and the
  # lines the Erlang expression eval prints with it loaded.
  def module_output(root:, eval:)
    Dir.mktmpdir('erx-keymap-test') do |work|
      include = File.join(work, 'include', 'generated')
      FileUtils.mkdir_p(include)
      schema = Erx::ABI::Model.validate(Erx::ABI::Sources.read(root: root))
      File.write(File.join(include, 'erx_abi.hrl'), Erx::ABI::ErlangEmitter.header(schema))
      plan = Erx::Keymap.generation(root: root)
      File.write(File.join(work, 'erx_keymap.erl'), plan.files.fetch(Erx::Keymap::OUTPUT))
      output, status = Open3.capture2e('gtimeout', '-k', '10', DEADLINE_SECONDS, ENV.fetch('ERX_ERLC'), '-Werror',
                                       '-I', File.join(work, 'include'), '-o', work, 'erx_keymap.erl',
                                       chdir: work, stdin_data: '')
      assert status.success?, output
      output, status = Open3.capture2e('gtimeout', '-k', '10', DEADLINE_SECONDS, ENV.fetch('ERX_ERL'), '-noshell',
                                       '-pa', work, '-eval', eval, chdir: work, stdin_data: '')
      assert status.success?, output
      output.lines.map(&:chomp)
    end
  end

  # One line for each code 0 to KEY_MAX the US layout has a row for.
  DUMP = <<~'ERLANG'
    Show = fun({key, #{none := N, shift := S, ctl := C, altgr := A, shiftaltgr := SA}, Caps}) ->
                   io_lib:format("key ~b ~b ~b ~b ~b ~w", [N, S, C, A, SA, Caps]);
              ({modifier, Rune, Modifier}) -> io_lib:format("modifier ~b ~w", [Rune, Modifier]);
              ({lock, Rune, Lock}) -> io_lib:format("lock ~b ~w", [Rune, Lock]);
              ({button, Bit}) -> io_lib:format("button ~b", [Bit])
           end,
    [io:format("~b ~s~n", [Code, Show(erx_keymap:row(us, Code))])
     || Code <- lists:seq(0, 16#2ff), erx_keymap:row(us, Code) =/= none],
    io:format("layouts ~w~n", [erx_keymap:layouts()]),
    halt(0).
  ERLANG

  # The US layout by evdev code (FreeBSD's input-event-codes.h) and 9front's runes
  # (sys/include/keyboard.h), written out from 9front's US map in kbdfs.c: a key that
  # types a character types it unshifted and shifted, and at ctl its low five bits
  # (Space and the grave accent nothing), and the keypad's slash, an escaped key there,
  # types itself at ctl; letters are the keys Caps Lock shifts. The altgr layers repeat
  # none and shift. Every other key types its special rune at all five layers. The rows
  # where the layout departs from kbdfs.c (listed in us.txt's header) follow the design,
  # so for those the table checks the generator and the design's choice, not 9front.
  module UsLayout
    # The first code of a run of keys, and each key's unshifted and shifted character.
    TYPING = [[2, '1!2@3#4$5%6^7&8*9(0)-_=+'], [16, 'qQwWeErRtTyYuUiIoOpP[{]}'],
              [30, %q(aAsSdDfFgGhHjJkKlL;:'"`~)], [43, '\\|zZxXcCvVbBnNmM,<.>/?'], [55, '**'],
              [57, '  '], [71, '778899--445566++11223300..'], [98, '//']].freeze
    CTL_ITSELF = [98].freeze
    SPECIAL = { 1 => 0x1b, 14 => 0x08, 15 => 0x09, 28 => 0x0a, 96 => 0x0a, 111 => 0x7f,
                59 => 0xf001, 60 => 0xf002, 61 => 0xf003, 62 => 0xf004, 63 => 0xf005, 64 => 0xf006,
                65 => 0xf007, 66 => 0xf008, 67 => 0xf009, 68 => 0xf00a, 87 => 0xf00b, 88 => 0xf00c,
                69 => 0xf865, 70 => 0xf019, 99 => 0xf010, 102 => 0xf00d, 103 => 0xf00e, 104 => 0xf00f,
                105 => 0xf011, 106 => 0xf012, 107 => 0xf018, 108 => 0xf800, 109 => 0xf013, 110 => 0xf014,
                119 => 0xf861, 125 => 0xf868, 126 => 0xf868 }.freeze
    OTHERS = { 42 => 'modifier 61462 shift', 54 => 'modifier 61462 shift', 29 => 'modifier 61463 ctl',
               97 => 'modifier 61463 ctl', 56 => 'modifier 61461 alt', 100 => 'modifier 61461 alt',
               58 => 'lock 63588 caps', 0x110 => 'button 1', 0x112 => 'button 2', 0x111 => 'button 4',
               0x14a => 'button 1' }.freeze

    def self.lines
      typed = TYPING.flat_map do |first, pairs|
        pairs.chars.each_slice(2).with_index.map do |(none, shift), index|
          code = first + index
          ctl = if CTL_ITSELF.include?(code) then none.ord
                elsif ['`', ' '].include?(none) then 0
                else none.ord & 0x1f
                end
          "#{code} key #{none.ord} #{shift.ord} #{ctl} #{none.ord} #{shift.ord} #{none.match?(/[a-z]/)}"
        end
      end
      special = SPECIAL.map { |code, rune| "#{code} key #{([rune] * 5).join(' ')} false" }
      typed + special + OTHERS.map { |code, row| "#{code} #{row}" }
    end
  end
end
