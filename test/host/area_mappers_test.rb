# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'minitest/autorun'
require 'tmpdir'
require_relative '../../tools/lib/erx/checks'
require_relative '../../tools/lib/erx/area_mappers'

# The chokepoint over who maps a pixel area. Its Erlang half: outside erx_area and
# erx_connections, erx_area is named only as the module of open/1 and of area(), and in
# erx_pixels also of lend/5, unlend/1 and zero/3; a call of map/4 in any form, an apply, an
# import, a macro, a list, tuple or map literal or a string naming it fails, and the
# tests' own modules are not refused. Its C half, over otp/erts/emulator: only the
# program driver calls the lease's driver functions, and only erx_area_lease_map maps
# into a space other than ERX_CAP_SELF.
class AreaMappersTest < Minitest::Test
  ROOT = File.expand_path('../..', __dir__)
  AGENT = 'erlang/apps/erx/src/erx_connections.erl'
  SCREEN = 'erlang/apps/erx_display/src/erx_screen.erl'
  SEEDED = "m(T) -> erx_area:map(21, 8192, read, T).\n"
  LENDER = Erx::AreaMappers::LENDER
  LEND = "f(A, O, P, H, T) -> erx_area:lend(A, O, P, H, T), erx_area:unlend(1), erx_area:zero(A, O, P).\n"
  DRIVER = Erx::AreaMappers::DRIVER
  NIF = Erx::AreaMappers::NIF
  LANE = 'otp/erts/emulator/sys/erxos/erx_lane_drv.c'
  FOREIGN = "\tstatus = erx_vm_map(space, addr, bytes, mem, 0, ERX_PROT_RW);\n"
  OWN = "\tstatus = erx_vm_map(ERX_CAP_SELF, addr, bytes, mem, 0, ERX_PROT_RW);\n"

  def lines_of(files) = Erx::AreaMappers.violations(files).map { |violation| [violation.path, violation.line] }

  def test_the_tree_passes
    globs = [*Erx::DeviceCallers::SCOPE, Erx::AreaMappers::C_SCOPE]
    paths = globs.flat_map { |glob| Dir.glob(glob, base: ROOT) }
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

  def test_only_the_lender_lends
    assert_empty lines_of(LENDER => LEND)
    assert_equal [[SCREEN, 1], [SCREEN, 1], [SCREEN, 1]], lines_of(SCREEN => LEND)
    assert_equal [[SCREEN, 1]], lines_of(SCREEN => "f() -> fun erx_area:unlend/1.\n")
    assert_equal [[LENDER, 1]], lines_of(LENDER => SEEDED)
  end

  def test_only_the_driver_calls_the_lease_functions
    %w[take map return].each do |name|
      call = "void f(void) { (void)erx_area_lease_#{name}(0, 0, 0); }\n"
      assert_equal [[LANE, 2]], lines_of(LANE => "/* erx_area_lease_#{name} in a comment */\n#{call}"), name
      assert_empty lines_of(DRIVER => call), name
    end
  end

  def test_only_the_lease_mapper_maps_into_another_space
    assert_equal [[DRIVER, 4]], lines_of(DRIVER => "int\nf(void)\n{\n#{FOREIGN}}\n")
    assert_empty lines_of(DRIVER => "int\nf(void)\n{\n#{OWN}}\n")
    assert_empty lines_of(NIF => "int\nerx_area_lease_map(void)\n{\n#{FOREIGN}}\n")
    assert_equal [[NIF, 9], [NIF, 1]], lines_of(NIF => "int\nerx_area_lease_map(void)\n{\n}\n\nint\nother(void)\n{\n#{FOREIGN}}\n")
    seeded = 'otp/erts/emulator/beam/seeded.c'
    assert_equal [[seeded, 1]], lines_of(seeded => "void f(void) { erx_vm_map(7, 0, 0, 0, 0, 0); }\n")
  end

  # A name of erx_vm_map not followed directly by its argument list could reach it through
  # a pointer or a parenthesized name, whose first argument the rule cannot see.
  def test_erx_vm_map_is_named_only_as_a_call
    assert_equal [[DRIVER, 4]], lines_of(DRIVER => "int\nf(void)\n{\n\tstatus = (erx_vm_map)(space, addr, bytes, mem, 0, 3);\n}\n")
    assert_equal [[DRIVER, 1]], lines_of(DRIVER => "static int (*map)(void) = erx_vm_map;\n")
    assert_equal [[DRIVER, 4]], lines_of(DRIVER => "int\nf(void)\n{\n\tstatus = erx_vm_map (ERX_CAP_SELF, 0, 0, 0, 0, 0);\n}\n")
  end

  # The function's body ends at its closing brace, so a helper defined after it, whatever
  # its first line looks like, is outside it; and the NIF maps into a program in one place.
  def test_the_nif_maps_into_another_space_once_inside_the_lease_mapper
    mapper = "int\nerx_area_lease_map(void)\n{\n#{FOREIGN}}\n"
    assert_equal [[NIF, 8]], lines_of(NIF => "#{mapper}\nstatic int helper(void) {\n#{FOREIGN}}\n")
    assert_equal [[NIF, 5]], lines_of(NIF => "int\nerx_area_lease_map(void)\n{\n#{FOREIGN}#{FOREIGN}}\n")
    assert_equal [[NIF, 1]], lines_of(NIF => "int\nerx_area_lease_map(void)\n{\n#{OWN}}\n")
  end

  # Strings are blanked before comments, so a string holding a comment's opening does not
  # hide the code after it.
  def test_a_string_does_not_hide_a_call
    text = "void\nf(void)\n{\n\tconst char *a = \"/*\";\n#{FOREIGN}\tconst char *b = \"*/\";\n}\n"
    assert_equal [[DRIVER, 5]], lines_of(DRIVER => text)
    assert_empty lines_of(DRIVER => "void\nf(void)\n{\n\tputs(\"erx_vm_map(space, 0)\");\n}\n")
  end

  def test_cpp_files_are_scanned
    seeded = 'otp/erts/emulator/beam/jit/seeded.cpp'
    assert Erx::AreaMappers.covers?(seeded)
    assert_equal [[seeded, 1]], lines_of(seeded => "void f() { erx_vm_map(7, 0, 0, 0, 0, 0); }\n")
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
