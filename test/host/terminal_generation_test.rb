# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'minitest/autorun'
require 'tmpdir'
require_relative '../../tools/lib/erx/terminal_generation'

class TerminalGenerationTest < Minitest::Test
  ROOT = File.expand_path('../..', __dir__).freeze

  def self.output_plan
    @output_plan ||= Erx::TerminalRules.plan(root: ROOT)
  end

  def source
    File.binread(File.join(ROOT, 'abi/terminal.txt'))
  end

  def test_unicode_notice_is_lossless_ascii_json
    plan = self.class.output_plan
    assert plan.values.all?(&:ascii_only?)
    notice = Erx::JsonInput.parse(plan.fetch('tools/generated/terminal_notices.json'))
    original = File.read(File.join(ROOT, 'otp/lib/stdlib/uc_spec/DerivedCoreProperties.txt'), encoding: Encoding::UTF_8)
                   .lines.take_while { |line| line.start_with?('#') || line.strip.empty? }.join
    assert_equal original, notice.fetch('original_unicode_notice')
    assert_equal 'Unicode-3.0', notice.fetch('license')
    assert_equal 4, notice.fetch('inputs').size
  end

  def test_policy_profiles_and_color_operands_are_separate
    model = Erx::TerminalRules.source(source)
    assert_equal [9, 10], model.fetch('pass').fetch('strict')
    assert_equal [9], model.fetch('pass').fetch('line')
    assert_equal [0x200c, 0x200d, 0xfe0e, 0xfe0f], model.fetch('exceptions')
    assert_equal({ 'sequence_bytes' => 64, 'parameters' => 16, 'digits' => 5,
                   'separator' => 59, 'intermediates' => [32, 47] }, model.fetch('grammar'))
    assert_equal({ 'prefix' => '<U+', 'minimum' => 4, 'maximum' => 6,
                   'suffix' => '>', 'digits' => 'uppercase_hex' }, model.fetch('token').fetch('codepoint'))
    refute_includes model.fetch('sgr').fetch('simple'), 8
    assert_includes model.fetch('sgr').fetch('simple'), 28
    assert_operator model.fetch('sgr').fetch('indexed').fetch('maximum'), :>=, 8
    assert_equal({ 'selectors' => [38, 48, 58], 'mode' => 5, 'operands' => 1, 'maximum' => 255 },
                 model.fetch('sgr').fetch('indexed'))
    assert_equal({ 'selectors' => [38, 48, 58], 'mode' => 2, 'operands' => 3, 'maximum' => 255 },
                 model.fetch('sgr').fetch('rgb'))
    assert_equal [7], model.fetch('literal').fetch('prim_tty/beep').fetch('bytes')
    refute model.fetch('literal').key?('terminal_mode/beep')
    assert model.frozen?
    assert model.fetch('sequence').values.all?(&:frozen?)
  end

  def test_malformed_declarations_are_typed_refusals
    [source + "unknown value\n", source + "terminal 1\n", source.sub('unicode 17.0.0', 'unicode latest'),
     source.sub('unsafe_categories Cc', 'unsafe_categories Cq'), source.sub('parameters=16', 'parameters=0'),
     source.sub('200C 200D', '200C 200C'), source.sub('sequence_bytes=64', 'sequence_bytes=99999'),
     source.sub('41 rows', '41 undefined'), source.sub('1B5B - - 41', '1B5D - - 41'),
     source.sub('sgr simple 0..7', 'sgr simple 0..8'), source.sub('reset keypad keypad_normal', 'reset keypad undefined'),
     source + "literal prim_tty bad 1B0\n", "\xff".b, 'x' * 65_537].each do |bytes|
      assert_raises(Erx::Error) { Erx::TerminalRules.source(bytes) }
    end
  end

  def test_reset_operands_and_compound_selectors_obey_the_allowlist
    [source.sub('reset rendition rendition 0', 'reset rendition rendition 8'),
     source.sub('reset cursor_visibility cursor_show 25', 'reset cursor_visibility cursor_show 9999'),
     source.sub('sgr indexed selectors=38,48,58', 'sgr indexed selectors=8'),
     source.sub('sgr rgb selectors=38,48,58', 'sgr rgb selectors=1')].each do |bytes|
      assert_raises(Erx::Error) { Erx::TerminalRules.source(bytes) }
    end
    color = source.sub('reset rendition rendition 0', 'reset rendition rendition 38,5,8')
    assert Erx::TerminalRules.source(color)
    assert_raises(Erx::Error) do
      Erx::TerminalRules.source(source.sub('reset rendition rendition 0', 'reset rendition rendition 38,5'))
    end
  end

  def record(point, name, category)
    [point, name, category, '0', 'L', '', '', '', '', 'N', '', '', '', '', ''].join(';') + "\n"
  end

  def test_unicode_range_pairs_and_property_versions_are_checked
    first = record('10000', '<Fixture, First>', 'Lo')
    last = record('10002', '<Fixture, Last>', 'Lo')
    assert_equal [[65536, 65538, 'Lo']], Erx::TerminalRules.unicode_data(first + last)
    [first, last, first + record('10002', '<Other, Last>', 'Lo'),
     first + record('10002', '<Fixture, Last>', 'Mn'), record('110000', 'BAD', 'Lo'),
     record('0041', 'A', 'Lu') * 2, '0041;short;Lu'].each do |bytes|
      assert_raises(Erx::Error) { Erx::TerminalRules.unicode_data(bytes) }
    end
    property = "# DerivedCoreProperties-17.0.0.txt\n034F ; Default_Ignorable_Code_Point # comment\n"
    assert_equal [[0x34f, 0x34f]], Erx::TerminalRules.derived_properties(property, version: '17.0.0')
    [property.sub('17.0.0', '16.0.0'), property + property.lines.last,
     property.sub('034F', '110000'), property.sub('Default_Ignorable_Code_Point', 'bad value')].each do |bytes|
      assert_raises(Erx::Error) { Erx::TerminalRules.derived_properties(bytes, version: '17.0.0') }
    end
  end

  def test_current_unicode_classes_match_independent_golden_points
    plan = self.class.output_plan
    Dir.mktmpdir('erx-terminal-ruby-') do |directory|
      path = File.join(directory, 'tables.rb')
      File.binwrite(path, plan.fetch('tools/generated/terminal_tables.rb'))
      load path
      ranges = Erx::Generated::TerminalTables::UNICODE_UNSAFE_RANGES
      unsafe = [0, 7, 9, 10, 0x7f, 0x85, 0x34f, 0x378, 0x115f, 0x200b, 0x2028, 0x2029,
                0x202e, 0x2066, 0x3164, 0xd800, 0xdfff, 0xfdd0, 0xfeff, 0xe0100, 0x10ffff]
      safe = [0x20, 0x41, 0x5d0, 0x200c, 0x200d, 0xe000, 0xfe0e, 0xfe0f, 0x1f600]
      unsafe.each { |point| assert ranges.any? { |first, last| point.between?(first, last) }, point.to_s(16) }
      safe.each { |point| refute ranges.any? { |first, last| point.between?(first, last) }, point.to_s(16) }
      assert ranges.each_cons(2).all? { |left, right| left.last + 1 < right.first }
    end
  end

  def test_missing_stale_and_orphan_outputs_are_detected_without_rewriting
    plan = self.class.output_plan
    Dir.mktmpdir('erx-terminal-drift-') do |directory|
      Erx::TerminalRules.publish(plan, root: directory)
      assert Erx::TerminalRules.check(plan, root: directory)
      target = File.join(directory, 'include/erx/terminal_ascii.h')
      File.write(target, 'stale')
      assert_raises(Erx::Error) { Erx::TerminalRules.check(plan, root: directory) }
      assert_equal 'stale', File.read(target)
      Erx::TerminalRules.publish(plan, root: directory)
      File.write(File.join(directory, 'tools/generated/terminal_orphan.rb'), 'orphan')
      assert_raises(Erx::Error) { Erx::TerminalRules.check(plan, root: directory) }
      Erx::TerminalRules.publish(plan, root: directory)
      refute File.exist?(File.join(directory, 'tools/generated/terminal_orphan.rb'))
      File.unlink(target)
      assert_raises(Erx::Error) { Erx::TerminalRules.check(plan, root: directory) }
    end
  end

  def test_publication_accepts_only_the_complete_owned_output_plan
    Dir.mktmpdir('erx-terminal-owner-') do |directory|
      root = File.join(directory, 'root')
      FileUtils.mkdir_p(root)
      invalid = self.class.output_plan.merge('../escape' => 'unexpected output')
      assert_raises(Erx::Error) { Erx::TerminalRules.publish(invalid, root: root) }
      refute File.exist?(File.join(directory, 'escape'))
    end
  end

  def test_later_linked_output_parent_is_rejected_before_rewriting_an_earlier_file
    plan = Erx::TerminalRules::OUTPUTS.to_h { |path| [path, 'new generated output'] }.freeze
    Dir.mktmpdir('erx-terminal-preflight-') do |directory|
      root = File.join(directory, 'root')
      outside = File.join(directory, 'outside')
      FileUtils.mkdir_p(File.join(root, 'include/erx'))
      Dir.mkdir(outside)
      target = File.join(root, 'include/erx/terminal_ascii.h')
      File.binwrite(target, 'keep existing output')
      File.symlink(outside, File.join(root, 'erlang'))
      assert_raises(Erx::Error) { Erx::TerminalRules.publish(plan, root: root) }
      assert_equal 'keep existing output', File.binread(target)
      assert_empty Dir.children(outside)
    end
  end
end
