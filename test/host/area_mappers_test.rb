# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'minitest/autorun'
require 'tmpdir'
require_relative '../../tools/lib/erx/checks'
require_relative '../../tools/lib/erx/area_mappers'

# The chokepoint "only the connection agent maps a pixel area": outside erx_area and
# erx_connections, erx_area is named only as the module of open/1 and of area(); a call
# of map/4 in any form, an apply, an import, a macro, a list, tuple or map literal or a
# string naming it fails, and the tests' own modules are not refused.
class AreaMappersTest < Minitest::Test
  ROOT = File.expand_path('../..', __dir__)
  AGENT = 'erlang/apps/erx/src/erx_connections.erl'
  SCREEN = 'erlang/apps/erx_display/src/erx_screen.erl'
  SEEDED = "m(T) -> erx_area:map(21, 8192, read, T).\n"

  def lines_of(files) = Erx::AreaMappers.violations(files).map { |violation| [violation.path, violation.line] }

  def test_the_tree_passes
    paths = Erx::DeviceCallers::SCOPE.flat_map { |glob| Dir.glob(glob, base: ROOT) }
    files = paths.to_h { |path| [path, File.binread(File.join(ROOT, path))] }
    assert_empty Erx::AreaMappers.violations(files).map(&:to_s)
  end

  def test_a_seeded_map_outside_the_agent_is_refused
    assert_equal [[SCREEN, 2]], lines_of(SCREEN => "%% erx_area:map(21, 8192, write, T) in a comment is not code\n#{SEEDED}")
    {
      'a fun' => "f() -> fun erx_area:map/4.\n",
      'quoted atoms' => "f(T) -> 'erx_area':'map'(21, 8192, write, T).\n",
      'a quoted module' => "f(T) -> 'erx_area':map(21, 8192, write, T).\n",
      'an apply' => "f(T) -> erlang:apply(erx_area, map, [21, 8192, write, T]).\n",
      'an apply with quoted atoms' => "f(T) -> apply('erx_area', 'map', [21, 8192, write, T]).\n",
      'an import' => "-import(erx_area, [open/1]).\n",
      'a macro' => "-define(AREA, erx_area).\n",
      'a list literal' => "f() -> [erx_area, map].\n",
      'a map literal' => "f() -> \#{module => erx_area, function => map}.\n",
      'a string' => "f() -> list_to_atom(\"erx_area\").\n",
      'a doc string' => "-doc \"\"\"\nUses the area erx_area:map/4 made.\n\"\"\".\n",
      'a call split across lines' => "f(T) ->\n    erx_area:\n        map(21, 8192, write, T).\n"
    }.each do |form, source|
      line = source.lines.index { |text| text.include?('erx_area') } + 1
      assert_equal [[SCREEN, line]], lines_of(SCREEN => source), form
    end
    assert_equal [['otp/lib/stdlib/src/seeded.erl', 1]], lines_of('otp/lib/stdlib/src/seeded.erl' => SEEDED)
  end

  def test_the_agent_open_area_and_tests_are_not_refused
    assert_empty lines_of(AGENT => SEEDED)
    assert_empty lines_of('erlang/apps/erx/src/erx_area.erl' => "-module(erx_area).\n#{SEEDED}")
    assert_empty lines_of(SCREEN => "-spec f(erx_area:area()) -> ok.\nf(P) -> erx_area:open(P), fun erx_area:open/1.\n")
    assert_empty lines_of(SCREEN => "f() -> \"see erx_area : open/1\", erx_area_unmapped, x:map(1, 2, 3, 4).\n")
    assert_empty lines_of('test/erlang/seeded_tests.erl' => SEEDED)
  end

  # The source check runs the rule over the files git lists.
  def test_the_source_check_refuses_a_seeded_violation
    Dir.mktmpdir do |root|
      FileUtils.mkdir_p(File.join(root, File.dirname(SCREEN)))
      File.write(File.join(root, SCREEN), SEEDED)
      checks = Erx::Checks.new(root: root, runner: nil)
      error = assert_raises(Erx::Error) { checks.send(:check_area_mappers, [SCREEN, 'README.md']) }
      assert_match "#{SCREEN}:1", error.message
    end
  end
end
