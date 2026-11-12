# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'fileutils'
require 'minitest/autorun'
require 'tmpdir'
require_relative '../../tools/lib/erx/erlang_apps'

# Which files make up an erXos application: its modules under erlang/apps/<app>/src
# and the generated ones at the same paths under build/gen, which the build compiles
# and the release's receipts name.
class ErlangAppsTest < Minitest::Test
  ErlangApps = Erx::ErlangApps

  def setup
    @root = File.realpath(Dir.mktmpdir('erx-erlang-apps-'))
  end

  def teardown
    FileUtils.remove_entry(@root) if @root
  end

  def write(path, text = File.basename(path))
    full = File.join(@root, path)
    FileUtils.mkdir_p(File.dirname(full))
    File.write(full, text)
  end

  def test_an_application_compiles_its_own_and_its_generated_modules
    write('erlang/apps/erx/src/erx_text.erl')
    write('build/gen/erlang/apps/erx/src/erx_text_tables.erl')
    write('build/gen/erlang/apps/erx/src/generated/erx_manifest.erl')
    assert_equal %w[build/gen/erlang/apps/erx/src/erx_text_tables.erl erlang/apps/erx/src/erx_text.erl
                    build/gen/erlang/apps/erx/src/generated/erx_manifest.erl].sort,
                 ErlangApps.modules(root: @root, application: 'erx').sort
  end

  def test_the_receipts_sources_name_generated_modules_and_the_resource_file
    write('erlang/apps/erx/src/erx_text.erl')
    write('build/gen/erlang/apps/erx/src/generated/erx_manifest.erl')
    sources = ErlangApps.sources(root: @root).select { |path| path.include?('/apps/erx/') }
    assert_equal %w[build/gen/erlang/apps/erx/src/generated/erx_manifest.erl erlang/apps/erx/src/erx.app.src
                    erlang/apps/erx/src/erx_text.erl].map { |path| File.join(@root, path) }, sources.sort
  end

  # An application that also runs outside erXos lists src/ alone in its .app.src; the
  # build adds erxos/ to the .app, and refuses a module in both, which would overwrite.
  def test_the_application_file_adds_erxos_modules_to_the_src_list
    write('erlang/apps/erx_net/src/erx_net_sup.erl')
    write('erlang/apps/erx_net/erxos/erx_virtio_net.erl')
    modules = ErlangApps.modules(root: @root, application: 'erx_net')
    erxos, src = ErlangApps.erxos_and_src('erx_net', modules)
    assert_equal [%w[erx_virtio_net], %w[erx_net_sup]], [erxos, src]
    text = '{application, erx_net, [{modules, [erx_net_sup]}, {env, []}]}.'
    assert_equal '{application, erx_net, [{modules, [erx_net_sup, erx_virtio_net]}, {env, []}]}.',
                 ErlangApps.with_modules(text, [*src, *erxos])
    write('erlang/apps/erx_net/erxos/erx_net_sup.erl')
    twice = ErlangApps.modules(root: @root, application: 'erx_net')
    assert_raises(Erx::Error) { ErlangApps.erxos_and_src('erx_net', twice) }
  end

  def app_src(modules) = "{application, erx, [{modules, [#{modules.join(', ')}]}]}.\n"

  # The source check runs ahead of any build, over every application directory.
  def test_the_source_check_refuses_a_module_the_application_file_does_not_list
    write('erlang/apps/erx/src/erx.app.src', app_src(%w[erx_text]))
    write('erlang/apps/erx/src/erx_text.erl')
    ErlangApps.check_sources(root: @root)
    write('erlang/apps/erx/src/erx_new.erl')
    error = assert_raises(Erx::Error) { ErlangApps.check_sources(root: @root) }
    assert_match(/erx\.app\.src lists erx_text but .* hold erx_new erx_text/, error.message)
  end

  def test_the_source_check_refuses_a_listed_module_that_does_not_exist
    write('erlang/apps/erx/src/erx.app.src', app_src(%w[erx_gone erx_text]))
    write('erlang/apps/erx/src/erx_text.erl')
    error = assert_raises(Erx::Error) { ErlangApps.check_sources(root: @root) }
    assert_match(/erx\.app\.src lists erx_gone erx_text but .* hold erx_text/, error.message)
  end

  def test_the_source_check_reads_an_unreleased_and_a_test_only_application
    write('erlang/apps/erx_display/src/erx_display.app.src', app_src(%w[erx_wm]))
    write('test/erlang/apps/erx_echo_test/src/erx_echo_test.app.src', app_src(%w[erx_echo]))
    write('test/erlang/apps/erx_echo_test/src/erx_echo.erl')
    error = assert_raises(Erx::Error) { ErlangApps.check_sources(root: @root) }
    assert_match(/erx_display\.app\.src lists erx_wm but .* hold \s*$/, error.message)
    write('erlang/apps/erx_display/src/erx_wm.erl')
    ErlangApps.check_sources(root: @root)
    write('test/erlang/apps/erx_echo_test/src/erx_extra.erl')
    error = assert_raises(Erx::Error) { ErlangApps.check_sources(root: @root) }
    assert_match(/erx_echo_test\.app\.src lists erx_echo but .* hold erx_echo erx_extra/, error.message)
  end

  # What the build refuses before compiling, so the check refuses it too: an application
  # directory no list names, and one with no application file.
  def test_the_source_check_refuses_an_unlisted_directory_and_a_missing_application_file
    write('erlang/apps/erx_new/src/erx_new.erl')
    error = assert_raises(Erx::Error) { ErlangApps.check_sources(root: @root) }
    assert_match(%r{erlang/apps holds applications ErlangApps does not list: erx_new}, error.message)
    FileUtils.rm_rf(File.join(@root, 'erlang/apps/erx_new'))
    write('erlang/apps/erx/src/erx_text.erl')
    error = assert_raises(Erx::Error) { ErlangApps.check_sources(root: @root) }
    assert_match(%r{erlang/apps/erx/src holds no erx\.app\.src}, error.message)
  end
end
