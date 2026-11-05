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
    assert_equal 2, notice.fetch('inputs').size
  end

  # The kernel's class is a printable range and nothing else: no line of the
  # source can admit a control to it.
  def test_the_kernel_class_admits_no_control
    assert_equal({ 'range' => [0x20, 0x7e] }, Erx::TerminalRules.source(source).fetch('kernel_ascii'))
    ['kernel_ascii 0020 007E 0009', 'kernel_ascii 001F 007E', 'kernel_ascii 0020 007F'].each do |line|
      forged = source.sub(/^kernel_ascii .*$/, line)
      assert_raises(Erx::Error, line) { Erx::TerminalRules.source(forged) }
    end
  end

  # Tab and newline are controls like the rest: no profile passes them, and
  # nothing in the source names a renderer, a sequence or a color.
  def test_the_line_escape_rules_have_no_allowlist
    model = Erx::TerminalRules.source(source)
    assert_equal %w[byte codepoint kernel], model.fetch('token').keys.sort
    assert_equal [0x200c, 0x200d, 0xfe0e, 0xfe0f], model.fetch('exceptions')
    assert_equal({ 'prefix' => '<U+', 'minimum' => 4, 'maximum' => 6,
                   'suffix' => '>', 'digits' => 'uppercase_hex' }, model.fetch('token').fetch('codepoint'))
    assert_equal %w[properties unicode_data], model.fetch('input').keys.sort
    refute_includes model.keys, 'pass'
    assert model.frozen?
  end

  def test_malformed_declarations_are_typed_refusals
    [source + "unknown value\n", source + "terminal 1\n", source.sub('unicode 17.0.0', 'unicode latest'),
     source.sub('unsafe_categories Cc', 'unsafe_categories Cq'), source.sub('200C 200D', '200C 200C'),
     source.sub('token byte <0x 2 2 >', 'token byte <0x 0 2 >'),
     source.sub(/^token kernel .*\n/, ''), source.sub(/^input properties .*\n/, ''),
     source + "pass strict 0009 000A\n", source + "sequence prim_tty cursor_up 1B5B - - 41 none\n",
     source + "input prim_tty otp/lib/kernel/src/prim_tty.erl\n", "\xff".b, 'x' * 65_537].each do |bytes|
      assert_raises(Erx::Error) { Erx::TerminalRules.source(bytes) }
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
