# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'fileutils'
require 'minitest/autorun'
require 'tmpdir'
require_relative '../../tools/lib/erx/display_release'

# G9's build check (Erx::DisplayRelease): the tree's display release holds no client
# module, and each seeded fault, a client module in the display release, erx's included,
# or a display module that names one, fails it.
class DisplayReleaseTest < Minitest::Test
  ROOT = File.expand_path('../..', __dir__)

  def app(name, modules, sources = {})
    { resource: "{application, #{name}, [{modules, [#{modules.join(', ')}]}]}.\n", sources: sources }
  end

  def client = { 'erx_win' => app('erx_win', %w[erx_draw_codec erx_win_app erx_tile]) }

  def display(modules: %w[erx_screen], source: "-module(erx_screen).\nf() -> ok.\n")
    { 'erx_display' => app('erx_display', modules, { 'erlang/apps/erx_display/src/erx_screen.erl' => source }) }
  end

  def test_the_tree_passes
    assert_empty Erx::DisplayRelease.check(root: ROOT)
  end

  # The check reads every application the display script boots, erx among them, so the
  # widget schema put back into erx, which every domain boots, fails it.
  def test_a_widget_module_in_erx_fails
    Dir.mktmpdir('erx-display-release-') do |root|
      { 'erx' => 'erx_ui_schema', 'erx_win' => 'erx_win_app' }.each do |name, module_name|
        directory = File.join(root, 'erlang/apps', name, 'src')
        FileUtils.mkdir_p(directory)
        File.write(File.join(directory, "#{name}.app.src"), "{application, #{name}, [{modules, [#{module_name}]}]}.\n")
        File.write(File.join(directory, "#{module_name}.erl"), "-module(#{module_name}).\n")
      end
      assert_includes Erx::DisplayRelease.check(root: root).map(&:where), 'erx lists erx_ui_schema'
    end
  end

  # The toolkit is an application of the client side, and the tree's erx_ui put into the
  # display release fails, by its listed modules, erx_ui_app among them.
  def test_the_toolkit_on_the_display_side_fails
    assert_includes Erx::DisplayRelease::CLIENT, 'erx_ui'
    toolkit = { 'erx_ui' => Erx::DisplayRelease.read_application(ROOT, 'erx_ui') }
    where = Erx::DisplayRelease.violations(display: toolkit, client: toolkit).map(&:where)
    assert_includes where, 'erx_ui lists erx_ui_app'
    assert_includes where, 'erx_ui lists erx_ui_server'
  end

  def test_a_display_module_that_documents_a_client_module_passes
    source = "%% erx_draw_core plans it.\n-moduledoc \"\"\"\nAs `erx_draw_image:decode/3` reads.\n\"\"\".\nf() -> ok.\n"
    assert_empty Erx::DisplayRelease.violations(display: display(source: source), client: client)
  end

  def test_a_client_module_listed_by_a_display_application_fails
    violations = Erx::DisplayRelease.violations(display: display(modules: %w[erx_screen erx_tile]), client: client)
    assert_equal ['display release (G9): erx_display lists erx_tile: a client module is not in the display release'],
                 violations.map(&:to_s)
  end

  def test_a_client_family_module_moved_to_the_display_side_fails
    violations = Erx::DisplayRelease.violations(display: display(modules: %w[erx_screen erx_draw_codec2]), client: {})
    assert_equal ['erx_display lists erx_draw_codec2'], violations.map(&:where)
  end

  def test_the_client_application_on_the_display_side_fails
    violations = Erx::DisplayRelease.violations(display: client, client: client)
    assert_equal %w[erx_draw_codec erx_win_app erx_tile].map { |name| "erx_win lists #{name}" }, violations.map(&:where)
  end

  def test_a_display_module_that_calls_a_client_module_fails
    source = "-module(erx_screen).\nf(B) ->\n    erx_tile:decode(B).\n"
    violations = Erx::DisplayRelease.violations(display: display(source: source), client: client)
    assert_equal ['erlang/apps/erx_display/src/erx_screen.erl:3: names the client module erx_tile'], violations.map { |v| "#{v.where}: #{v.rule}" }
  end

  # The program handler may name the pixel allocator (MAY_NAME); any other module of the
  # display side that names it still fails, and the handler naming another client module too.
  def test_only_the_handler_names_the_pixel_allocator
    handler = 'erlang/apps/erx/src/erx_prog_handler.erl'
    other = 'erlang/apps/erx/src/erx_pipe_srv.erl'
    sources = { handler => "f() -> erx_pixels:alloc(1, 2), erx_tile:decode(<<>>).\n",
                other => "f() -> erx_pixels:alloc(1, 2).\n" }
    violations = Erx::DisplayRelease.violations(display: { 'erx' => app('erx', %w[erx_prog_handler erx_pipe_srv], sources) },
                                                client: client)
    assert_equal ["#{handler}:1: names the client module erx_tile", "#{other}:1: names the client module erx_pixels"],
                 violations.map { |v| "#{v.where}: #{v.rule}" }
  end
end
