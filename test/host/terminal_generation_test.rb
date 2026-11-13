# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'fileutils'
require 'minitest/autorun'
require 'tmpdir'
require_relative '../../tools/lib/erx/terminal_generation'

class TerminalGenerationTest < Minitest::Test
  ROOT = File.expand_path('../..', __dir__).freeze
  GENERATION_FILES = %w[abi/terminal.txt tools/gen_terminal.rb tools/lib/erx/terminal_generation.rb
                        tools/lib/erx/terminal_rules.rb otp/lib/stdlib/uc_spec/UnicodeData.txt
                        otp/lib/stdlib/uc_spec/DerivedCoreProperties.txt
                        otp/lib/stdlib/uc_spec/EastAsianWidth.txt].freeze
  WIDTH_MODULE = 'erlang/apps/erx_win/src/erx_vt_width.erl'
  WIDTH_HEADER = 'include/erx/vt_width.h'
  FIXTURE_REVIEW = { 'rules' => [], 'default_license' => 'Unicode-3.0',
                     'default_evidence' => 'terminal generation fixture' }.freeze

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
    assert_equal 3, notice.fetch('inputs').size
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

  # The source holds only the line escape rules; the golden points below pin
  # that tab and newline are escaped.
  def test_the_source_declares_only_the_line_escape_rules
    model = Erx::TerminalRules.source(source)
    assert_equal %w[byte codepoint field kernel], model.fetch('token').keys.sort
    assert_equal({ 'prefix' => '\x', 'minimum' => 2, 'maximum' => 2,
                   'suffix' => '', 'digits' => 'uppercase_hex' }, model.fetch('token').fetch('field'))
    assert_equal [0x200c, 0x200d, 0xfe0e, 0xfe0f], model.fetch('exceptions')
    assert_equal({ 'prefix' => '<U+', 'minimum' => 4, 'maximum' => 6,
                   'suffix' => '>', 'digits' => 'uppercase_hex' }, model.fetch('token').fetch('codepoint'))
    assert_equal %w[east_asian_width properties unicode_data], model.fetch('input').keys.sort
    assert model.frozen?
  end

  def test_malformed_declarations_are_typed_refusals
    [source + "unknown value\n", source + "terminal 1\n", source.sub('unicode 17.0.0', 'unicode latest'),
     source.sub('unsafe_categories Cc', 'unsafe_categories Cq'), source.sub('200C 200D', '200C 200C'),
     source.sub('token byte <0x 2 2 >', 'token byte <0x 0 2 >'),
     source.sub(/^token kernel .*\n/, ''), source.sub(/^token field .*\n/, ''),
     source.sub('token byte <0x 2 2 >', 'token byte <0x 2 3 >'),
     source.sub('token codepoint <U+ 4 6 >', 'token codepoint <U+ 4 5 >'),
     # A field token that could be read as \t, \n or \\, or is not a
     # backslash form, would make the field escape ambiguous.
     *['\t 2 2 -', 'x 2 2 -', '\x 2 2 ;', '\\\\ 2 2 -', '\x 2 3 -', '\xy 2 2 -'].map do |forged|
       source.sub('token field \x 2 2 -', "token field #{forged}")
     end,
     source.sub(/^input properties .*\n/, ''),
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

  # ORIGIN.md lists every imported OTP file, so rebuilding any preloaded beam
  # rewrites it. Only the import rows of the two Unicode inputs bear on the
  # generated files, so a root whose ORIGIN.md differs elsewhere generates the
  # same files from the same recorded reads, and the build tree stays fresh.
  def test_an_unrelated_origin_entry_leaves_the_plan_unchanged
    Dir.mktmpdir('erx-terminal-origin-') do |directory|
      plain = generation_root(File.join(directory, 'plain'))
      wider = generation_root(File.join(directory, 'wider'),
                              extra: { 'otp/lib/kernel/ebin/unrelated.beam' => 'rebuilt beam' })
      refute_equal File.binread(File.join(plain, 'otp/ORIGIN.md')), File.binread(File.join(wider, 'otp/ORIGIN.md'))
      assert_equal Erx::TerminalRules.generation(root: plain), Erx::TerminalRules.generation(root: wider)
    end
  end

  # Re-importing an input with different bytes changes what generation reads,
  # so the recorded reads change and the build tree regenerates, even though the
  # tables come out the same (the added line is a comment and changes no interval).
  # The same bytes edited in place carry the change notice that ORIGIN.md
  # accepts, yet generation refuses them: it reads only imported bytes.
  def test_a_reimported_input_changes_the_recorded_reads
    properties = 'otp/lib/stdlib/uc_spec/DerivedCoreProperties.txt'
    version_line, *rest = File.binread(File.join(ROOT, properties)).lines
    edited = [version_line, "# Modified by erXos: terminal generation fixture\n", *rest].join
    Dir.mktmpdir('erx-terminal-reimport-') do |directory|
      plain = generation_root(File.join(directory, 'plain'))
      changed = generation_root(File.join(directory, 'changed'), extra: { properties => edited })
      old_plan = Erx::TerminalRules.generation(root: plain)
      new_plan = Erx::TerminalRules.generation(root: changed)
      tables = Erx::TerminalRules::OUTPUTS.take(3)
      assert_equal old_plan.files.slice(*tables), new_plan.files.slice(*tables)
      refute_equal old_plan.reads.fetch(properties), new_plan.reads.fetch(properties)
      File.binwrite(File.join(plain, properties), edited)
      error = assert_raises(Erx::Error) { Erx::TerminalRules.plan(root: plain) }
      assert_equal 'terminal input differs from its pinned OTP origin', error.message
    end
  end

  # The generated files declare Unicode-3.0 themselves, so an input imported
  # under any other licence is refused rather than relabelled.
  def test_an_input_imported_under_another_license_is_refused
    Dir.mktmpdir('erx-terminal-license-') do |directory|
      root = generation_root(directory, review: FIXTURE_REVIEW.merge('default_license' => 'MIT'))
      error = assert_raises(Erx::Error) { Erx::TerminalRules.plan(root: root) }
      assert_equal 'terminal input differs from its pinned OTP origin', error.message
    end
  end

  # erx_vt's width table agrees, code point by code point, with widths derived
  # here straight from UnicodeData.txt and EastAsianWidth.txt by the design's
  # rule; a source that leaves F out of the wide values does not.
  def test_the_width_table_agrees_with_the_unicode_data
    expected = derived_widths
    assert_equal expected, table_widths(self.class.output_plan.fetch(WIDTH_MODULE))
    Dir.mktmpdir('erx-terminal-width-') do |directory|
      root = generation_root(directory, extra: { 'abi/terminal.txt' => source.sub("width_wide W F\n", "width_wide W\n") })
      refute_equal expected, table_widths(Erx::TerminalRules.plan(root: root).fetch(WIDTH_MODULE))
    end
  end

# The C width function libvterm is built with holds the same widths, so the
# oracle comparison of erx_vt never differs on a width.
def test_the_c_width_table_agrees_with_the_unicode_data
  widths = Array.new(0x110000, 1)
  self.class.output_plan.fetch(WIDTH_HEADER)
      .scan(/\{ 0x(\h+), 0x(\h+), ([02]) \}/) { |first, last, width| widths.fill(width.to_i, first.hex..last.hex) }
  assert_equal derived_widths, widths
end

  private

  def derived_widths
    widths = Array.new(0x110000, 1)
    File.foreach(File.join(ROOT, 'otp/lib/stdlib/uc_spec/EastAsianWidth.txt')) do |line|
      next unless (match = line.match(/\A(\h+)(?:\.\.(\h+))?\s*;\s*(W|F)\s/))

      widths.fill(2, match[1].hex..(match[2] || match[1]).hex)
    end
    first = nil
    File.foreach(File.join(ROOT, 'otp/lib/stdlib/uc_spec/UnicodeData.txt')) do |line|
      point, name, category = line.split(';')
      first = point.hex if name.end_with?('First>')
      next if name.end_with?('First>') || !%w[Mn Me Cf].include?(category)

      widths.fill(0, (name.end_with?('Last>') ? first : point.hex)..point.hex)
    end
    widths[0xad] = 1
    widths
  end

  def table_widths(text)
    widths = Array.new(0x110000, 1)
    text.scan(/\{16#(\h+), 16#(\h+), ([02])\}/) { |first, last, width| widths.fill(width.to_i, first.hex..last.hex) }
    widths
  end


  # A minimal tree generation can run in: its sources, the two Unicode inputs
  # (extra adds files or replaces their bytes) and an OTP import recorded over
  # exactly the otp/ files written.
  def generation_root(root, extra: {}, review: FIXTURE_REVIEW)
    GENERATION_FILES.to_h { |path| [path, File.binread(File.join(ROOT, path))] }.merge(extra).each do |path, bytes|
      FileUtils.mkdir_p(File.dirname(File.join(root, path)))
      File.binwrite(File.join(root, path), bytes)
    end
    Erx::Origin.new(root: File.join(root, 'otp'))
               .write(repository: 'https://example.invalid/otp.git', revision: 'fixture',
                      archive_sha256: '0' * 64, review: review)
    root
  end
end
