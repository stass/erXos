# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'fileutils'
require 'minitest/autorun'
require 'open3'
require 'tmpdir'
require_relative '../fixtures/erlang_build'
require_relative '../fixtures/square_font'
require_relative '../../tools/lib/erx/glyphs'
require_relative '../../tools/lib/erx/origin'
require_relative '../../tools/lib/erx/memdraw_build'

# The glyph step (docs/design-desktop-programs.md, "Type"): erx-raster, built
# once from the fetched FreeType pin (tools/erx fetch --source freetype) into
# a temporary directory, and Erx::Glyphs over it. A square glyph's coverage
# lands exactly where its geometry puts it, and an erx-raster seeded with a
# one-pixel shift fails that; the theme's subfonts are byte-identical over two
# runs, each parses with erx_font and loads into erx_draw_core on stock's
# emulator (ERX_ERL and ERX_ERLC, which make check supplies); and a role whose
# font lacks a tabular figure, or one with a glyph whose ink leaves its line,
# is refused. The body role's menu module places each square as its subfont
# does, and the theme's loads with erx_memdraw:load/3 on the host NIF and holds
# the body subfont's image, glyphs and pairs, the last by character, where a
# module whose kern/2 is keyed by glyph index fails.
class GlyphsTest < Minitest::Test
  ROOT = File.expand_path('../..', __dir__)
  THEME = File.read(File.join(ROOT, 'abi/theme.txt')).freeze
  # The ABI's resolved types, which hold the palettes and ui_role the theme refers to.
  TYPES = Erx::ABI::Model.validate(Erx::ABI::Sources.read(root: ROOT)).types
  # The one-pixel shift: every glyph's top one row higher than FreeType put it.
  SHIFT = ['put_u32((uint32_t)(int32_t)slot->bitmap_top);', 'put_u32((uint32_t)(int32_t)slot->bitmap_top + 1);'].freeze
  DEADLINE_SECONDS = '300'
  OTP = File.join(ROOT, 'build/oracle/jit/install/lib/erlang')

  # erx-raster, built once for every case: the tree's, and the one seeded
  # with SHIFT.
  def self.programs
    @programs ||= begin
      work = Dir.mktmpdir('erx-glyphs-test-')
      Minitest.after_run { FileUtils.remove_entry(work) }
      runner = Erx::Runner.new(owner_root: work, log_dir: File.join(work, 'logs'))
      %w[tree seeded].each { |name| Dir.mkdir(File.join(work, name)) }
      source = File.read(File.join(ROOT, Erx::Raster::PROGRAM_SOURCE))
      raise "the shift's anchor is not once in #{Erx::Raster::PROGRAM_SOURCE}" unless source.scan(SHIFT.first).size == 1

      seeded = File.join(work, 'erx_raster.c')
      File.write(seeded, source.sub(SHIFT.first, SHIFT.last))
      { runner: runner,
        tree: Erx::Raster::Build.new(root: ROOT, runner: runner, output_root: File.join(work, 'tree')).call,
        seeded: Erx::Raster::Build.new(root: ROOT, runner: runner, output_root: File.join(work, 'seeded'),
                                       program: seeded).call }.freeze
    end
  end

  def setup
    @work = Dir.mktmpdir('erx-glyphs-case-')
  end

  def teardown = FileUtils.remove_entry(@work)

  def test_square_glyph_coverage_is_exact
    assert_equal expected_squares.encode, File.binread(square_subfont(:tree).subfonts.fetch('body'))
  end

  def test_one_pixel_shift_fails_the_square_test
    refute_equal expected_squares.encode, File.binread(square_subfont(:seeded).subfonts.fetch('body'))
  end

  def test_theme_subfonts_are_byte_identical_over_two_runs
    first, second = %w[first second].map { |name| write_theme(File.join(@work, name).tap { |path| Dir.mkdir(path) }) }
    assert_equal first.subfonts.keys, second.subfonts.keys
    first.subfonts.each { |role, path| assert_equal File.binread(path), File.binread(second.subfonts.fetch(role)), "role #{role}" }
    first.lvgl.each { |role, path| assert_equal File.read(path), File.read(second.lvgl.fetch(role)), "role #{role}'s LVGL font" }
    assert_equal File.read(first.menu), File.read(second.menu)
  end

  def test_theme_subfonts_parse_and_load_in_a_draw_connection
    subfonts = write_theme(File.join(@work, 'roles').tap { |path| Dir.mkdir(path) }).subfonts
    assert_equal theme_of(THEME).roles.keys, subfonts.keys
    ErlangBuild.compile(@work, applications: %w[erx_win], tests: %w[test/erlang/erx_glyph_subfonts_tests.erl])
    FileUtils.cp(subfonts.values, @work)
    output, status = Open3.capture2e('gtimeout', '-k', '10', DEADLINE_SECONDS, ENV.fetch('ERX_ERL'), '-noshell',
                                     '-pa', @work, '-eval',
                                     'halt(case eunit:test(erx_glyph_subfonts_tests, [verbose]) of ok -> 0; _ -> 1 end)',
                                     chdir: @work, stdin_data: '')
    assert status.success?, output
    assert_match(/All #{subfonts.size + 1} tests passed/, output)
  end

  def test_role_whose_font_lacks_a_tabular_figure_is_refused
    fonts = File.join(@work, 'display/fonts/inter')
    FileUtils.mkdir_p(fonts)
    medium = File.binread(File.join(ROOT, 'display/fonts/inter/Inter-Medium.ttf'))
    # The post table's name of one.tf, a Pascal string of six bytes.
    name = "\x06one.tf".b
    assert_equal 1, medium.scan(name).size, 'the post table names one.tf once'
    File.binwrite(File.join(fonts, 'Inter-Medium.ttf'), medium.sub(name, "\x06one.tx".b))
    import(fonts, rules: { '*' => 'OFL-1.1' }, copyright: 'Copyright (c) 2016 The Inter Project Authors')
    theme = theme_of(THEME.gsub(/^  role .*\n/, '')
                          .sub("  # The spacing scale", "  role numeric font ui size 13 line 20 weight medium figures tabular\n  # The spacing scale"),
                     roles: %w[numeric])
    error = assert_raises(Erx::Glyphs::Refused) { write(root: @work, theme: theme, program: :tree) }
    assert_equal 'role numeric: its font has no tabular figure one.tf', error.message
  end

  # The display role in a 56-pixel line: Inter SemiBold's accented capitals
  # and bar leave it at 48 pixels.
  def test_glyph_whose_ink_leaves_the_line_is_refused
    display = THEME[/^  role display .*\n/].sub(/ line \d+ /, ' line 56 ')
    theme = theme_of(THEME.gsub(/^  role .*\n/, '').sub('  # The spacing scale', "#{display}  # The spacing scale"), roles: %w[display])
    error = assert_raises(Erx::Glyphs::Refused) { write(root: ROOT, theme: theme, program: :tree, output_root: @work) }
    assert_match(/\Arole display: U\+[0-9A-F]{4} leaves the line, rows -?\d+ to \d+ of 56\z/, error.message)
  end

  # The menu module of the theme's body role loads into a k8 image with
  # erx_memdraw:load/3, on the host NIF, and holds the body subfont's image,
  # glyphs and pairs; the same module with kern/2 keyed by glyph index fails
  # the pairs' case.
  def test_menu_module_loads_with_erx_memdraw
    written = write_theme(File.join(@work, 'roles').tap { |path| Dir.mkdir(path) })
    menu = File.read(written.menu)
    output, status = menu_cases(menu, written.subfonts.fetch('body'), 'tree')
    assert status.success?, output
    assert_match(/\b3 tests passed/, output)
    points = body_points
    by_index = menu.gsub(/^kern\(16#(\h+), 16#(\h+)\)/) { "kern(#{points.index(Regexp.last_match(1).hex)}, #{points.index(Regexp.last_match(2).hex)})" }
    refute_equal menu, by_index, 'the module has no kern clause'
    output, status = menu_cases(by_index, written.subfonts.fetch('body'), 'by-index')
    refute status.success?, "a menu module keyed by glyph index passed:\n#{output}"
    assert_match(/kern_is_the_subfonts_test\.\.\.\*failed\*/, output)
  end

  # The squares' menu module gives each square the rectangle, offset and
  # advance of its subfont entry (expected_squares), and none for a
  # character outside the range.
  def test_menu_module_places_each_glyph
    menu = square_subfont(:tree).menu
    ErlangBuild.compile(@work, applications: [], tests: [menu])
    output = erlang('io:format("~w~n", [[case erx_menu_glyphs:glyph(C) of none -> none; G -> lists:sort(maps:to_list(G)) end ' \
                    '|| C <- lists:seq(16#40, 16#44)]]), halt(0)')
    glyphs = [[0, 11, 4, 15, 1, 6], [4, 10, 9, 15, 1, 6], [9, 13, 13, 17, -1, 7]].map do |x0, y0, x1, y1, left, advance|
      "[{advance,#{advance}},{left,#{left}},{r,{#{x0},#{y0},#{x1},#{y1}}}]"
    end
    assert_equal "[none,#{glyphs.join(',')},none]", output.lines.last.chomp
  end

  # Every generated file of the theme holds glyph data derived from Inter,
  # so it declares the license Inter's import records for the role's font
  # file and names that file, Inter's release and Inter's copyright line,
  # and not erXos's own license, which covers the generators.
  def test_generated_files_declare_the_fonts_license
    written = write_theme(File.join(@work, 'roles').tap { |path| Dir.mkdir(path) })
    theme = theme_of(THEME)
    copyright = File.foreach(File.join(ROOT, 'display/fonts/inter/LICENSE.txt')).first.chomp
    [*written.lvgl, ['body', written.menu]].each do |name, path|
      role = theme.roles.fetch(name)
      file = theme.fonts.fetch(role.font).files.fetch(role.weight)
      text = File.read(path)
      head = text.lines.first(4).join
      assert_includes head, "SPDX-License-Identifier: OFL-1.1\n", path
      assert_includes head, "Glyph data derived from #{file} v4.1, #{copyright}\n", path
      refute_includes text, 'BSD-2-Clause', path
    end
  end

  # The license is the one the font's import records for the font file: the
  # square font's import records Apache-2.0 for Square.ttf and MIT for the
  # rest.
  def test_generated_files_take_the_license_the_fonts_import_records
    written = square_subfont(:tree)
    [written.menu, written.lvgl.fetch('body')].each do |path|
      head = File.read(path).lines.first(4).join
      assert_includes head, "SPDX-License-Identifier: Apache-2.0\n", path
      assert_includes head, "Glyph data derived from Square.ttf v1.0, Copyright (c) 2026 The Square Test\n", path
    end
  end

  # A font file that is not the one its import records, as when it changed
  # after the import, is refused before any glyph is rasterised.
  def test_font_file_its_import_does_not_record_is_refused
    square_import
    File.binwrite(File.join(@work, 'fonts/Square.ttf'), SquareFont.bytes + "\0".b)
    error = assert_raises(Erx::Glyphs::Refused) { write(root: @work, theme: square_theme, program: :tree) }
    assert_equal 'role body: fonts/Square.ttf is not the file its ORIGIN.md row records', error.message
  end

  private

  # The body role's character of each subfont glyph index.
  def body_points
    theme = theme_of(THEME)
    Erx::Glyphs.code_points(theme.fonts.fetch(theme.roles.fetch('body').font))
  end

  # The menu glyph module's cases over MENU, the source of erx_menu_glyphs, and
  # the body subfont at SUBFONT, with body.points beside them, in a directory
  # NAME of the case's: the output and status.
  def menu_cases(menu, subfont, name)
    directory = File.join(@work, name).tap { |path| Dir.mkdir(path) }
    File.write(File.join(directory, Erx::Glyphs::Menu::FILE), menu)
    File.write(File.join(directory, 'body.points'), "[#{body_points.join(',')}].\n")
    FileUtils.cp(subfont, directory)
    ErlangBuild.compile(directory, applications: %w[erx_win erx_memdraw],
                                   tests: [File.join(directory, Erx::Glyphs::Menu::FILE), 'test/erlang/erx_menu_glyphs_tests.erl'])
    Erx::MemdrawBuild.nif(root: ROOT, otp: OTP, directory: directory, compiler: ENV.fetch('ERX_CLANG', 'clang'))
    environment = Erx::MemdrawBuild::CLEAN_ENVIRONMENT.merge(Erx::HostOs.nif_search_environment(directory))
    Open3.capture2e(environment, 'gtimeout', '-k', '10', DEADLINE_SECONDS, ENV.fetch('ERX_ERL'), '-noshell', '-pa', directory,
                    '-eval', 'halt(case eunit:test(erx_menu_glyphs_tests, [verbose]) of ok -> 0; _ -> 1 end)',
                    chdir: directory, stdin_data: '')
  end

  # What the emulator printed for EXPRESSION, run in the case's directory,
  # which must succeed.
  def erlang(expression)
    environment = Erx::MemdrawBuild::CLEAN_ENVIRONMENT.merge(Erx::HostOs.nif_search_environment(@work))
    output, status = Open3.capture2e(environment, 'gtimeout', '-k', '10', DEADLINE_SECONDS, ENV.fetch('ERX_ERL'),
                                     '-noshell', '-pa', @work, '-eval', expression, chdir: @work, stdin_data: '')
    assert status.success?, output
    output
  end


  # Glyphs over the square font, an import of its own whose ORIGIN.md
  # records it as Apache-2.0: a role of U+0041 to U+0043 at 16 pixels in
  # a 20-pixel line, through the tree's or the seeded erx-raster.
  def square_subfont(program)
    square_import
    write(root: @work, theme: square_theme, program: program)
  end

  # The square font as an import of its own beneath @work/fonts.
  def square_import
    FileUtils.mkdir_p(File.join(@work, 'fonts'))
    File.binwrite(File.join(@work, 'fonts/Square.ttf'), SquareFont.bytes)
    import(File.join(@work, 'fonts'), rules: { 'Square.ttf' => 'Apache-2.0', '*' => 'MIT' },
                                      copyright: 'Copyright (c) 2026 The Square Test')
  end

  def square_theme
    rows = <<~ROWS.gsub(/^/, '  ').chomp
      font square fonts regular Square.ttf
      range square 0041-0043
      role body font square size 16 line 20 weight regular
      # The spacing scale
    ROWS
    theme_of(THEME.gsub(/^  (?:font|range|role) .*\n/, '').sub('  # The spacing scale', rows), roles: %w[body])
  end

  # DIRECTORY's files as an import at release v1.0 with a LICENSE.txt whose
  # first line is COPYRIGHT, each file's license the first of RULES whose
  # pattern it matches: package rules, which a font's file of no notice of
  # its own takes.
  def import(directory, rules:, copyright:)
    File.write(File.join(directory, 'LICENSE.txt'), "#{copyright}\n")
    review = { 'rules' => rules.map { |pattern, license| { 'kind' => 'package', 'pattern' => pattern, 'license' => license, 'evidence' => 'test' } },
               'default_license' => 'NOASSERTION', 'default_evidence' => 'test' }
    Erx::Origin.new(root: directory).write(repository: 'https://example.invalid/fonts', revision: 'v1.0 (test)',
                                           archive_sha256: '0' * 64, review: review)
  end

  # The squares' subfont as their geometry gives it. The ascender and
  # descender, 13 and 3 pixels, leave 4 pixels of the 20-pixel line, so the
  # baseline is row 2 + 13 = 15. U+0041 covers whole pixels: 4 by 4, rows 11
  # to 15, one pixel right of the pen. U+0042, moved half a pixel, touches 5
  # by 5 pixels, rows 10 to 15: half of each edge pixel, a quarter of each
  # corner. U+0043 covers 4 by 4 whole pixels from 2 rows above the baseline
  # to 2 below, rows 13 to 17, one pixel left of the pen, and its advance of
  # 6.5 pixels rounds up to 7.
  def expected_squares
    whole = Array.new(4) { [255] * 4 }
    edge = [64, *[128] * 3, 64]
    half = [edge, *Array.new(3) { [128, 255, 255, 255, 128] }, edge]
    rows = Array.new(20) { [0] * 13 }
    whole.each_with_index { |row, index| rows[11 + index][0, 4] = row }
    half.each_with_index { |row, index| rows[10 + index][4, 5] = row }
    whole.each_with_index { |row, index| rows[13 + index][9, 4] = row }
    glyphs = [Erx::Glyphs::Glyph.new(x: 0, top: 11, bottom: 15, left: 1, width: 6),
              Erx::Glyphs::Glyph.new(x: 4, top: 10, bottom: 15, left: 1, width: 6),
              Erx::Glyphs::Glyph.new(x: 9, top: 13, bottom: 17, left: -1, width: 7)]
    Erx::Glyphs::Subfont.new(width: 13, height: 20, ascent: 15, pixels: rows.flatten.pack('C*'), glyphs: glyphs)
  end

  # The theme's roles, written beneath output_root.
  def write_theme(output_root) = write(root: ROOT, theme: theme_of(THEME), program: :tree, output_root: output_root)

  def write(root:, theme:, program:, output_root: root)
    programs = self.class.programs
    Erx::Glyphs.write(root: root, program: programs.fetch(program), runner: programs.fetch(:runner), theme: theme,
                      output_root: output_root)
  end

  # The theme of TEXT. A case that cuts the theme down to a few role rows
  # names them as ROLES, and the theme reads against a ui_role of those
  # members alone, so its rows still name ui_role's members one for one.
  def theme_of(text, roles: nil)
    types = roles ? TYPES.merge(Erx::ABI::Theme::ROLE_ENUM => ui_role_of(roles)) : TYPES
    Erx::ABI::Theme.validate(Erx::ABI::Syntax.parse(text, path: 'abi/theme.txt').select { |item| item.kind == 'theme' },
                             types: types)
  end

  # The tree's ui_role with ROLES as its members, valued in order.
  def ui_role_of(roles)
    Erx::ABI::EnumType.new(**TYPES.fetch(Erx::ABI::Theme::ROLE_ENUM).to_h, members: roles.each_with_index.to_h.freeze).freeze
  end
end
